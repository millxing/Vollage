import AppKit
import CoreImage
import AVFoundation

final class Compositor {
    let context = CIContext(options: [.cacheIntermediates: false])
    func image(clips: [Clip], size: CGSize) -> CIImage {
        let bounds = CGRect(origin: .zero, size: size)
        var canvas = CIImage(color: .black).cropped(to: bounds)
        for clip in clips {
            let state = clip.state
            let rect = CGRect(x: state.x * size.width, y: (1 - state.y - state.height) * size.height, width: state.width * size.width, height: state.height * size.height)
            guard rect.width > 0, rect.height > 0 else { continue }
            var layer = CIImage(color: .black).cropped(to: rect)
            if var source = clip.frame() {
                source = source.transformed(by: CGAffineTransform(translationX: -source.extent.minX, y: -source.extent.minY))
                if state.mirrored { source = source.transformed(by: CGAffineTransform(scaleX: -1, y: 1)).transformed(by: CGAffineTransform(translationX: source.extent.width, y: 0)) }
                let scale = min(rect.width / source.extent.width, rect.height / source.extent.height)
                source = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                source = source.transformed(by: CGAffineTransform(translationX: rect.midX - source.extent.midX, y: rect.midY - source.extent.midY))
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
