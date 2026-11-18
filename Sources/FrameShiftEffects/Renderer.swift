// Adapted from FrameShift's Metal stack renderer.
import Foundation
import CoreVideo
import Metal

public final class EffectEngine {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    fileprivate let pipelines: [String: MTLComputePipelineState]
    fileprivate let emptyHistory: MTLTexture
    fileprivate let emptyFrame: MTLTexture
    private let textureCache: CVMetalTextureCache

    public init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError.unavailable
        }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: ShaderSource.code, options: nil)
        pipelines = try Dictionary(uniqueKeysWithValues: library.functionNames.map { name in
            guard let function = library.makeFunction(name: name) else { throw RenderError.unavailable }
            return (name, try device.makeComputePipelineState(function: function))
        })
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw RenderError.unavailable }
        textureCache = cache
        emptyHistory = try Self.texture(device, width: 1, height: 1, format: .rgba8Unorm, depth: 1)
        emptyFrame = try Self.texture(device, width: 1, height: 1, format: .rgba16Float)
    }

    fileprivate static func texture(
        _ device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat, depth: Int? = nil, renderTarget: Bool = false
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        if renderTarget { descriptor.usage.insert(.renderTarget) }
        if let depth {
            descriptor.textureType = .type2DArray
            descriptor.arrayLength = depth
        }
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw RenderError.allocation }
        return texture
    }

    public func outputTexture(for pixel: CVPixelBuffer) throws -> (MTLTexture, CVMetalTexture) {
        var reference: CVMetalTexture?
        let attributes = [kCVMetalTextureUsage as String: MTLTextureUsage.shaderWrite.rawValue] as CFDictionary
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache, pixel, attributes, .bgra8Unorm,
            CVPixelBufferGetWidth(pixel), CVPixelBufferGetHeight(pixel), 0, &reference
        )
        guard status == kCVReturnSuccess, let reference, let texture = CVMetalTextureGetTexture(reference) else {
            throw RenderError.allocation
        }
        return (texture, reference)
    }
}

public enum RenderError: LocalizedError {
    case unavailable, allocation
    public var errorDescription: String? {
        switch self {
        case .unavailable: "Video effects are unavailable."
        case .allocation: "Unable to allocate memory for video effects."
        }
    }
}

private struct KernelInfo {
    let width: UInt32
    let height: UInt32
    var head: UInt32 = 0
    var depth: UInt32 = 1
    var filled: UInt32 = 1
    let time: Float
    var hasPrevious: UInt32 = 0
}

/// One renderer per video. Frame history and feedback belong to each effect instance.
public final class EffectRenderer {
    private final class State {
        let history: MTLTexture?
        let feedback: [MTLTexture]
        var head = 0
        var filled = 0
        var current = 0
        var written = false
        var hasPrevious = false

        init(engine: EffectEngine, width: Int, height: Int, kind: EffectKind) throws {
            history = kind == .slitScan
                ? try EffectEngine.texture(engine.device, width: width, height: height, format: .rgba8Unorm, depth: 64)
                : nil
            feedback = kind == .videoFeedback
                ? try (0..<2).map { _ in
                    try EffectEngine.texture(engine.device, width: width, height: height, format: .rgba16Float)
                }
                : []
        }
    }

    private let engine: EffectEngine
    private let scratch: [MTLTexture]
    private var states: [UUID: State] = [:]
    private var order: [UUID] = []
    public let input: MTLTexture

    public init(engine: EffectEngine, width: Int, height: Int) throws {
        self.engine = engine
        input = try EffectEngine.texture(engine.device, width: width, height: height, format: .rgba16Float, renderTarget: true)
        scratch = try (0..<3).map { _ in
            try EffectEngine.texture(engine.device, width: width, height: height, format: .rgba16Float)
        }
    }

    public func reset() {
        states.removeAll()
        order.removeAll()
    }

    public func encode(
        _ effects: [EffectInstance], time: Double, isNewFrame: Bool,
        output: MTLTexture, into command: MTLCommandBuffer
    ) throws {
        let ids = effects.map(\.id)
        if ids != order {
            reset()
            order = ids
        }

        // Allocate before encoding any passes, so a failed allocation cannot leave a partial stack.
        for effect in effects where states[effect.id] == nil {
            states[effect.id] = try State(engine: engine, width: input.width, height: input.height, kind: effect.kind)
        }
        guard let encoder = command.makeComputeCommandEncoder() else { throw RenderError.unavailable }
        defer { encoder.endEncoding() }
        let size = MTLSize(width: input.width, height: input.height, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        func dispatch(_ name: String) {
            encoder.setComputePipelineState(engine.pipelines[name]!)
            encoder.dispatchThreads(size, threadsPerThreadgroup: group)
        }

        var current = input
        for effect in effects {
            let state = states[effect.id]!
            var info = KernelInfo(width: UInt32(input.width), height: UInt32(input.height), time: Float(time))
            if let history = state.history {
                if isNewFrame || state.filled == 0 {
                    if state.filled > 0 { state.head = (state.head + 1) % history.arrayLength }
                    state.filled = min(state.filled + 1, history.arrayLength)
                }
                var slot = UInt32(state.head)
                encoder.setTexture(current, index: 0)
                encoder.setTexture(history, index: 1)
                encoder.setBytes(&slot, length: MemoryLayout<UInt32>.size, index: 0)
                dispatch("k_push")
                info.head = slot
                info.depth = UInt32(history.arrayLength)
                info.filled = UInt32(state.filled)
            }

            var previous = engine.emptyFrame
            var accumulator = engine.emptyFrame
            if !state.feedback.isEmpty {
                if isNewFrame && state.written {
                    state.current = 1 - state.current
                    state.hasPrevious = true
                }
                state.written = true
                accumulator = state.feedback[state.current]
                previous = state.feedback[1 - state.current]
                info.hasPrevious = state.hasPrevious ? 1 : 0
            }

            let processed = scratch.first { $0 !== current }!
            let values = effect.kernelValues
            encoder.setTexture(current, index: 0)
            encoder.setTexture(processed, index: 1)
            encoder.setTexture(state.history ?? engine.emptyHistory, index: 2)
            encoder.setTexture(previous, index: 3)
            encoder.setTexture(accumulator, index: 4)
            values.withUnsafeBufferPointer { encoder.setBytes($0.baseAddress!, length: $0.count * MemoryLayout<Float>.stride, index: 0) }
            encoder.setBytes(&info, length: MemoryLayout<KernelInfo>.stride, index: 1)
            dispatch("k_" + effect.kind.rawValue)

            var mix = Float(effect.value(ParamSpec.mix.key))
            if mix < 1 {
                let result = scratch.first { $0 !== current && $0 !== processed }!
                encoder.setTexture(current, index: 0)
                encoder.setTexture(result, index: 1)
                encoder.setTexture(processed, index: 2)
                encoder.setBytes(&mix, length: MemoryLayout<Float>.size, index: 0)
                dispatch("k_mix")
                current = result
            } else {
                current = processed
            }
        }

        encoder.setTexture(current, index: 0)
        encoder.setTexture(output, index: 1)
        dispatch("k_output")
    }
}
