import AppKit
import CoreImage
import AVFoundation

final class Compositor {
    let context = CIContext(options: [.cacheIntermediates: false])
    private lazy var effectPipeline = Result { try EffectFramePipeline() }
    private var retryEffectsAfter = 0.0

    func updateEffects(clips: [Clip], outputSize: CGSize) throws {
        guard clips.contains(where: {
            $0.effectFrames != nil || $0.state.effectStack.contains(where: \.isEnabled)
        }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= retryEffectsAfter else { return }
        do {
            try effectPipeline.get().update(clips, outputSize: outputSize)
        } catch {
            retryEffectsAfter = now + 2
            throw error
        }
    }

    func image(clips: [Clip], size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        var canvas = CIImage(color: .black).cropped(to: bounds)
        for clip in clips {
            let state = clip.state
            // Whole-pixel tile edges keep every frame sampled the same way, which avoids shimmer.
            let rect = CGRect(x: state.x * size.width, y: (1 - state.y - state.height) * size.height, width: state.width * size.width, height: state.height * size.height).integral
            guard rect.width > 0, rect.height > 0 else { continue }
            var layer = CIImage(color: .black).cropped(to: rect)
            let hasEffects = state.effectStack.contains(where: \.isEnabled)
            let frame = hasEffects ? (clip.effectFrames?.image ?? clip.lastImage) : clip.frame()
            if var source = frame {
                source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                if state.mirrored { source = source.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).transformed(by: CGAffineTransform(translationX: source.extent.width, y: 0)) }
                let scale = min(rect.width / source.extent.width, rect.height / source.extent.height)
                if scale < 1 {
                    // A light blur first averages the pixels the shrink would drop. Without it, detailed footage shimmers.
                    let extent = source.extent
                    source = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 0.5 / scale]).cropped(to: extent)
                }
                source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                source = source.transformed(by: CGAffineTransform(translationX: (rect.midX - source.extent.midX).rounded(), y: (rect.midY - source.extent.midY).rounded()))
                layer = source.composited(over: layer).cropped(to: rect)
            }
            let filters = ["screen": "CIScreenBlendMode", "multiply": "CIMultiplyBlendMode", "difference": "CIDifferenceBlendMode", "overlay": "CIOverlayBlendMode"]
            if let filter = filters[state.blend] { canvas = layer.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: canvas]).cropped(to: bounds) }
            else { canvas = layer.composited(over: canvas).cropped(to: bounds) }
        }
        return canvas
    }
    func png(clips: [Clip], size: CGSize) -> Data? {
        let frame = image(clips: clips, size: size)
        return context.pngRepresentation(of: frame, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
    }
}
