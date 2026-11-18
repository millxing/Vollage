import AVFoundation
import Observation
import CoreImage

@Observable final class Clip: Identifiable {
    var state: VideoState { didSet { sync() } }
    var id: String { state.id }
    let player: AVQueuePlayer
    let looper: AVPlayerLooper
    var rating = 0
    @ObservationIgnored var globalPaused = false
    @ObservationIgnored var output: AVPlayerItemVideoOutput?
    @ObservationIgnored var outputItem: AVPlayerItem?
    @ObservationIgnored private(set) var lastImage: CIImage?
    @ObservationIgnored private(set) var frameSerial: UInt64 = 0
    @ObservationIgnored private(set) var frameTime = 0.0
    @ObservationIgnored private(set) var isSeeking = false
    @ObservationIgnored private var seekSerial: UInt64 = 0
    @ObservationIgnored var effectFrames: EffectFrames?
    init(_ state: VideoState, globalPaused: Bool) {
        self.state = state; self.globalPaused = globalPaused
        player = AVQueuePlayer()
        let item = AVPlayerItem(url: URL(fileURLWithPath: state.playbackPath))
        item.audioTimePitchAlgorithm = .varispeed
        looper = AVPlayerLooper(player: player, templateItem: item)
        sync()
        if state.time > 0 { seek(to: state.time) }
    }
    func sync() {
        player.isMuted = state.muted; player.volume = state.volume
        let rate: Float = globalPaused || state.paused ? 0 : state.speed
        if player.rate != rate { player.rate = rate }
    }
    func snapshot() -> VideoState {
        var copy = state
        let time = player.currentTime().seconds
        if time.isFinite { copy.time = max(0, time) }
        return copy
    }
    var duration: Double {
        let value = player.currentItem?.duration.seconds ?? 0
        return value.isFinite ? max(0, value) : 0
    }
    func seek(to time: Double) {
        seekSerial &+= 1
        let request = seekSerial
        isSeeking = true
        player.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, request == self.seekSerial else { return }
                self.lastImage = nil
                self.effectFrames = nil
                self.isSeeking = false
            }
        }
    }
    func frame() -> CIImage? {
        guard !isSeeking else { return lastImage }
        if outputItem !== player.currentItem {
            if let output, let outputItem { outputItem.remove(output) }
            let next = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
            player.currentItem?.add(next); output = next; outputItem = player.currentItem
        }
        let time = player.currentTime()
        var displayTime = CMTime.invalid
        // Only effect videos need to know when a frame is new. Plain videos fetch every tick, as before.
        if let output, (lastImage == nil || state.effects?.isEmpty != false || output.hasNewPixelBuffer(forItemTime: time)),
           let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) {
            var frame = CIImage(cvPixelBuffer: pixel)
            if let t = state.orientation, t.count == 6 {
                // Track display matrices use top-left coordinates; Core Image uses bottom-left.
                let flip = CGAffineTransform(scaleX: 1, y: -1)
                let transform = CGAffineTransform(a: t[0], b: t[1], c: t[2], d: t[3], tx: t[4], ty: t[5])
                frame = frame.transformed(by: flip).transformed(by: transform).transformed(by: flip)
            }
            lastImage = frame
            frameSerial &+= 1
            frameTime = displayTime.seconds.isFinite ? displayTime.seconds : 0
        }
        return lastImage
    }
    var originalURL: URL {
        let source = URL(fileURLWithPath: state.sourcePath)
        return FileManager.default.fileExists(atPath: source.path) ? source : URL(fileURLWithPath: state.path)
    }
}
