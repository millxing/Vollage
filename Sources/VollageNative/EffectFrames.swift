import CoreImage
import CoreVideo
import FrameShiftEffects
import Metal

/// Holds the processed frame until the next canvas tick. Reading it never advances history.
final class EffectFrames {
    private let renderer: EffectRenderer
    private let pool: CVPixelBufferPool
    let width: Int
    let height: Int
    private(set) var image: CIImage?
    private var lastSample: UInt64?
    private var lastStack: [EffectInstance] = []
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    init(engine: EffectEngine, width: Int, height: Int) throws {
        self.width = width
        self.height = height
        renderer = try EffectRenderer(engine: engine, width: width, height: height)
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { throw RenderError.allocation }
        self.pool = pool
    }

    func encode(
        source: CIImage, sample: UInt64, time: Double, effects: [EffectInstance],
        engine: EffectEngine, context: CIContext, command: MTLCommandBuffer
    ) throws -> (CVPixelBuffer, CVMetalTexture)? {
        guard lastSample != sample || lastStack != effects else { return nil }
        var pixel: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else {
            throw RenderError.allocation
        }
        let (target, reference) = try engine.outputTexture(for: pixel)
        let extent = source.extent
        let input = source.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(width) / extent.width, y: CGFloat(height) / extent.height))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let destination = CIRenderDestination(mtlTexture: renderer.input, commandBuffer: command)
        // FrameShift samples row zero at the top, as does the output pixel buffer.
        destination.isFlipped = true
        destination.colorSpace = Self.colorSpace
        _ = try context.startTask(toRender: input, from: bounds, to: destination, at: .zero)
        try renderer.encode(effects, time: time, isNewFrame: lastSample != sample, output: target, into: command)
        lastSample = sample
        lastStack = effects
        return (pixel, reference)
    }

    func publish(_ pixel: CVPixelBuffer) {
        image = CIImage(cvPixelBuffer: pixel, options: [.colorSpace: Self.colorSpace])
    }
}

final class EffectFramePipeline {
    private static let engineResult = Result { try EffectEngine() }
    private let engine: EffectEngine
    private let context: CIContext
    private let budget = 512 * 1024 * 1024
    private let maximumSide = 1920.0

    init() throws {
        engine = try Self.engineResult.get()
        context = CIContext(mtlCommandQueue: engine.queue, options: [.cacheIntermediates: false])
    }

    func update(_ clips: [Clip], outputSize: CGSize) throws {
        var inputs: [(clip: Clip, source: CIImage, stack: [EffectInstance], width: Double, height: Double, bytes: Double)] = []
        for clip in clips {
            let stack = clip.state.effectStack.filter(\.isEnabled)
            guard !stack.isEmpty else { clip.effectFrames = nil; continue }
            _ = clip.frame()
            guard !clip.isSeeking, let source = clip.lastImage, !source.extent.isEmpty else { continue }
            let size = source.extent.size
            let scale = min(1, clip.state.width * outputSize.width / size.width,
                            clip.state.height * outputSize.height / size.height, maximumSide / max(size.width, size.height))
            let width = max(2, size.width * scale), height = max(2, size.height * scale)
            // Four working textures, an output pair, and any effect-specific history or feedback.
            let bytesPerPixel = stack.reduce(40) { bytes, effect in
                switch effect.kind {
                case .slitScan: bytes + 64 * 4
                case .videoFeedback: bytes + 2 * 8
                case .displacementMap: bytes
                }
            }
            inputs.append((clip, source, stack, width, height, width * height * Double(bytesPerPixel)))
        }
        guard !inputs.isEmpty, let command = engine.queue.makeCommandBuffer() else { return }

        let bytes = inputs.reduce(0) { $0 + $1.bytes }
        let scale = min(1, (Double(budget) / bytes).squareRoot())
        var pending: [(EffectFrames, CVPixelBuffer, CVMetalTexture)] = []
        var failure: (any Error)?
        for input in inputs {
            let width = max(2, Int(input.width * scale))
            let height = max(2, Int(input.height * scale))
            do {
                if input.clip.effectFrames?.width != width || input.clip.effectFrames?.height != height {
                    input.clip.effectFrames = try EffectFrames(engine: engine, width: width, height: height)
                }
                guard let frames = input.clip.effectFrames else { continue }
                if let (pixel, reference) = try frames.encode(
                    source: input.source, sample: input.clip.frameSerial, time: input.clip.frameTime,
                    effects: input.stack, engine: engine, context: context, command: command
                ) {
                    pending.append((frames, pixel, reference))
                }
            } catch {
                input.clip.effectFrames = nil
                failure = error
            }
        }

        if !pending.isEmpty {
            // One submission for all effect videos. Both canvas and recorder consume the completed frames.
            command.commit()
            command.waitUntilCompleted()
            withExtendedLifetime(pending) {}
            if command.status == .completed {
                for (frames, pixel, _) in pending { frames.publish(pixel) }
            } else {
                for input in inputs { input.clip.effectFrames = nil }
                failure = command.error ?? RenderError.unavailable
            }
        }
        if let failure { throw failure }
    }
}
