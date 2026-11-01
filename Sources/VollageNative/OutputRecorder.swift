import AVFoundation
import CoreImage

final class OutputRecorder {
    let size: CGSize
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let destination: URL
    let temporary: URL
    var frames: Int64 = 0
    var isFinishing = false
    var samples: [String: Data] = [:]
    var preparing = Set<String>()
    var audioPositions: [String: Double] = [:]
    var audioTicks: [String: Int] = [:]
    var start = ProcessInfo.processInfo.systemUptime
    var lastTick = -1
    init(url: URL, size: CGSize) throws {
        self.size = CGSize(width: max(2, Int(size.width) / 2 * 2), height: max(2, Int(size.height) / 2 * 2))
        destination = url; temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
        writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(self.size.width), AVVideoHeightKey: Int(self.size.height)])
        audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000])
        video.expectsMediaDataInRealTime = true; audio.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: Int(self.size.width), kCVPixelBufferHeightKey as String: Int(self.size.height), kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(video), writer.canAdd(audio) else { throw VollageError.message("MP4 encoding is unavailable.") }
        writer.add(video); writer.add(audio)
    }
    func cacheAudio(_ states: [VideoState]) async throws {
        for path in Set(states.map(\.playbackPath)) where !preparing.contains(path) {
            samples[path] = try await MediaLibrary.shared.audio(path); preparing.insert(path)
        }
    }
    func prepareAudio(_ states: [VideoState]) async throws {
        try await cacheAudio(states)
        guard writer.startWriting() else { throw writer.error ?? VollageError.message("Cannot start output recording.") }
        writer.startSession(atSourceTime: .zero)
        start = ProcessInfo.processInfo.systemUptime
    }
    func append(_ clips: [Clip], compositor: Compositor) throws {
        guard writer.status == .writing else { throw writer.error ?? VollageError.message("Recording stopped unexpectedly.") }
        guard video.isReadyForMoreMediaData, audio.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return }
        let tick = Int((ProcessInfo.processInfo.systemUptime - start) * 30)
        guard tick > lastTick else { return }; lastTick = tick
        // Continuous 30 fps timeline: audio and video always advance together.
        var pixel: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixel) == kCVReturnSuccess, let pixel else { throw VollageError.message("Cannot allocate an output frame.") }
        compositor.context.render(compositor.image(clips: clips, size: size), to: pixel)
        let time = CMTime(value: Int64(tick), timescale: 30)
        guard adaptor.append(pixel, withPresentationTime: time) else { throw writer.error ?? VollageError.message("Could not write video frame.") }
        var mixed = [Float](repeating: 0, count: 1600 * 2)
        for clip in clips where clip.globalPaused || clip.state.paused || clip.state.muted || clip.state.speed == 0 { audioPositions[clip.id] = nil; audioTicks[clip.id] = nil }
        for clip in clips where !clip.globalPaused && !clip.state.paused && !clip.state.muted && clip.state.speed > 0 {
            let path = clip.state.playbackPath
            if samples[path] == nil, !preparing.contains(path) {
                preparing.insert(path)
                Task { do { samples[path] = try await MediaLibrary.shared.audio(path) } catch { /* A newly added clip without decodable audio remains silent. */ } }
            }
            guard let data = samples[path], data.count >= 8 else { continue }
            let seconds = clip.player.currentTime().seconds; guard seconds.isFinite else { continue }
            data.withUnsafeBytes { bytes in
                let source = bytes.bindMemory(to: Float.self); let count = source.count / 2
                let actual = (max(0, seconds) * 48000).truncatingRemainder(dividingBy: Double(count))
                var cursor = audioPositions[clip.id] ?? actual
                if let previous = audioTicks[clip.id] { cursor += Double(max(0, tick-previous-1) * 1600) * Double(clip.state.speed) }
                cursor = cursor.truncatingRemainder(dividingBy: Double(count))
                let difference = abs(actual-cursor)
                // Follow explicit seeking, while avoiding per-frame AVPlayer clock jitter.
                if min(difference, Double(count)-difference) > 4800 { cursor = actual }
                for i in 0..<1600 {
                    let position = (cursor + Double(i) * Double(clip.state.speed)).truncatingRemainder(dividingBy: Double(count))
                    let a = Int(position), b = (a + 1) % count, fraction = Float(position - Double(a))
                    for channel in 0..<2 { mixed[i * 2 + channel] += (source[a * 2 + channel] * (1 - fraction) + source[b * 2 + channel] * fraction) * clip.state.volume }
                }
                audioPositions[clip.id] = (cursor + 1600 * Double(clip.state.speed)).truncatingRemainder(dividingBy: Double(count))
                audioTicks[clip.id] = tick
            }
        }
        for i in mixed.indices { mixed[i] = min(1, max(-1, mixed[i])) }
        var block: CMBlockBuffer?
        let byteCount = mixed.count * MemoryLayout<Float>.size
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr, let block else { throw VollageError.message("Could not allocate output audio.") }
        mixed.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
        var description = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?; var sampleSize = 8
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &buffer) == noErr, let buffer, audio.append(buffer) else { throw writer.error ?? VollageError.message("Could not write output audio.") }
        frames += 1
    }
    func finish() async throws {
        isFinishing = true
        video.markAsFinished(); audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? VollageError.message("Recording could not finish.") }
        if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: destination) }
    }
}
