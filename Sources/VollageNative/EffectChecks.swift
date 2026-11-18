import AppKit
import AVFoundation
import FrameShiftEffects
import SwiftUI

// The effects pilot needs real decoded frames and a real MP4 writer to verify timing.
enum EffectChecks {
    static func run(_ model: CanvasModel, root: URL, check: (Bool, String) -> Void) async throws {
        let media = root.appendingPathComponent("motion")
        let names = ["Displacement", "Slit-Scan", "Feedback", "Reference"]
        let urls = names.map { media.appendingPathComponent($0 + ".mp4") }
        await model.importVideos(urls)
        guard model.clips.count == 4 else { throw VollageError.message("Unable to load the effect test videos.") }
        let clips = model.clips
        let size = CGSize(width: 1920, height: 1080)
        model.document.canvasWidth = size.width
        model.document.canvasHeight = size.height
        model.arrange()
        model.document.folderPath = media.path
        model.document.count = 4
        model.folder = try await MediaLibrary.shared.files(in: media)

        let kinds: [EffectKind] = [.displacementMap, .slitScan, .videoFeedback]
        for (clip, kind) in zip(clips, kinds) {
            var effect = EffectInstance(kind: kind)
            switch kind {
            case .displacementMap: effect.set("source", 1); effect.set("amount", 0.12)
            case .slitScan: effect.set("span", 48)
            case .videoFeedback: effect.set("blend", 1); effect.set("amount", 0.72)
            default: break
            }
            model.select(clip)
            model.edit { $0.state.effectStack = [effect] }
        }
        await wait(2)
        check(clips.prefix(3).allSatisfy { $0.effectFrames?.image != nil }, "all three Metal effects render")
        check(clips[3].effectFrames == nil, "reference video uses the original frame")

        model.captureScene(0)
        model.renameScene(0, "Three Effects")
        let project = root.appendingPathComponent("FrameShift Effects Demo.vollage")
        try await ProjectStore.shared.save(model.snapshot(), to: project)
        let (saved, _) = try await ProjectStore.shared.load(project)
        let expected = clips.map { $0.state.effectStack }
        check(saved.videos.map(\.effectStack) == expected, "project reload restores effect settings")
        check(saved.scenes[0]?.videos.map(\.effectStack) == expected, "scene stores effect stacks")

        model.togglePlayback()
        await wait(0.35)
        let serials = clips.map(\.frameSerial)
        let effected = try frame(model, size: size)
        await wait(0.25)
        let stationary = try frame(model, size: size)
        check(clips.map(\.frameSerial) == serials && difference(effected, stationary, in: clips[2].state) < 0.001,
              "paused feedback remains stable across redraws and snapshots")

        for clip in clips.prefix(3) { clip.state.effectStack[0].isEnabled = false }
        await wait(0.15)
        let bypassed = try frame(model, size: size)
        for (clip, kind) in zip(clips, kinds) {
            check(difference(effected, bypassed, in: clip.state) > 0.01, "\(kind.title) makes a visible change")
        }
        check(difference(effected, bypassed, in: clips[3].state) < 0.001, "bypass leaves the reference tile unchanged")

        model.select(clips[0])
        model.edit {
            $0.state.effectStack = expected[0]
            $0.state.effectStack[0].set("mix", 0)
        }
        await wait(0.2)
        let transparent = try frame(model, size: size)
        let zeroMixDifference = difference(transparent, bypassed, in: clips[0].state)
        check(zeroMixDifference < 0.025, "zero Mix preserves source orientation and color (mean error \(String(format: "%.3f", zeroMixDifference)))")
        check(clips[0].frameSerial == serials[0], "paused parameter edits use the same decoded frame")
        model.edit { $0.state.effectStack[0].set("mix", 1) }
        await wait(0.2)
        let adjusted = try frame(model, size: size)
        check(difference(transparent, adjusted, in: clips[0].state) > 0.01, "Mix edits update the paused picture")
        model.undo()
        check(model.selected?.state.effectStack.first?.value("mix") == 0, "Undo restores the prior effect setting")
        model.redo()
        check(model.selected?.state.effectStack.first?.value("mix") == 1, "Redo restores the new effect setting")

        await wait(0.2)
        if let primary = model.selected {
            var second = EffectInstance(kind: .displacementMap)
            second.set("source", 2)
            second.set("amount", 0.18)
            model.edit { $0.state.effectStack.append(second) }
            await wait(0.2)
            let originalOrder = try frame(model, size: size)
            model.edit { $0.state.effectStack.swapAt(0, 1) }
            await wait(0.2)
            let changedOrder = try frame(model, size: size)
            check(difference(originalOrder, changedOrder, in: primary.state) > 0.01,
                  "reordering two effects changes their composed result")
        }

        model.recallScene(0)
        check(model.clips.map { $0.state.effectStack } == expected, "scene recall restores the effect stacks")
        await wait(1.25)
        let recorder = try OutputRecorder(url: root.appendingPathComponent("live-effects.mp4"), size: size)
        try await recorder.prepareAudio(model.clips.map(\.state))
        let feedback = model.clips[2]
        let feedbackFrames = feedback.effectFrames
        model.recording = recorder
        await wait(20)
        model.recording = nil
        let elapsed = ProcessInfo.processInfo.systemUptime - recorder.start
        try await recorder.finish()
        let fps = Double(recorder.frames) / elapsed
        check(recorder.frames >= 570, "Full HD live recording wrote \(recorder.frames)/600 nominal frames (\(String(format: "%.1f", fps)) fps)")
        check(feedback.effectFrames === feedbackFrames && feedback.looper.loopCount > 0,
              "recording and normal loops preserve the feedback renderer")

        // The same paused processed frame also passes through the real H.264 encoder.
        model.togglePlayback()
        await wait(0.3)
        let preview = try frame(model, size: size)
        let stillURL = root.appendingPathComponent("paused-effects.mp4")
        let still = try OutputRecorder(url: stillURL, size: size)
        try await still.prepareAudio(model.clips.map(\.state))
        model.recording = still
        await wait(0.45)
        model.recording = nil
        try await still.finish()
        let asset = AVURLAsset(url: stillURL)
        let generator = AVAssetImageGenerator(asset: asset)
        let recorded = NSBitmapImageRep(cgImage: try await generator.image(at: CMTime(seconds: 0.2, preferredTimescale: 600)).image)
        check(recorded.pixelsWide == 1920 && recorded.pixelsHigh == 1080, "recorded output is 1920 × 1080")
        check(model.clips.allSatisfy { difference(preview, recorded, in: $0.state) < 0.04 },
              "decoded MP4 matches the composed preview across all four tiles")

        model.select(feedback)
        let beforeSeek = feedback.effectFrames
        let beforeSeekSerial = feedback.frameSerial
        model.seek(1.75)
        await wait(0.6)
        check(feedback.effectFrames?.image != nil && feedback.effectFrames !== beforeSeek
              && feedback.frameSerial > beforeSeekSerial && abs(feedback.frameTime - 1.75) < 0.1,
              "paused seek clears history and processes the destination frame")
        let priorIDs = Set(model.clips.map(\.id))
        await model.shuffleNow()
        check(priorIDs.isDisjoint(with: model.clips.map(\.id)) && model.clips.map { $0.state.effectStack } == expected,
              "shuffle transfers settings to replacement videos")

        try await captureInspector(model, saved: saved, check: check)
    }

    static func captureInspector(_ model: CanvasModel, saved: DocumentState, check: (Bool, String) -> Void) async throws {
        guard let directory = ProcessInfo.processInfo.environment["VOLLAGE_SNAPSHOTS"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        model.apply(saved)
        model.select(model.clips[0])
        model.window?.setContentSize(NSSize(width: 1320, height: 940))
        for (mode, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            await wait(0.5)
            let path = "\(directory)/effects-\(mode).png"
            if model.window?.isKeyWindow == true && NSApp.isActive {
                await NativeChecks.capture(path, model, check)
            } else {
                // AppKit controls and scroll views need a host even when the screen is locked.
                let bounds = CGRect(x: 0, y: 0, width: CanvasModel.sidebarWidth, height: 900)
                let host = NSHostingView(rootView: InspectorView(model: model)
                    .frame(width: bounds.width, height: bounds.height)
                    .environment(\.colorScheme, mode == "light" ? .light : .dark))
                let offscreen = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
                offscreen.appearance = NSAppearance(named: appearance)
                offscreen.contentView = host
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                guard let image = host.bitmapImageRepForCachingDisplay(in: bounds) else {
                    throw VollageError.message("Unable to render the offscreen Effects inspector.")
                }
                host.cacheDisplay(in: bounds, to: image)
                guard let data = image.representation(using: .png, properties: [:]) else {
                    throw VollageError.message("Unable to save the offscreen Effects inspector.")
                }
                try data.write(to: URL(fileURLWithPath: path))
                withExtendedLifetime(offscreen) {}
                check(true, "offscreen Effects inspector snapshot (\(mode))")
            }
        }
    }

    private static func frame(_ model: CanvasModel, size: CGSize) throws -> NSBitmapImageRep {
        guard let data = model.compositor.png(clips: model.clips, size: size),
              let image = NSBitmapImageRep(data: data) else {
            throw VollageError.message("Unable to read the composed output.")
        }
        return image
    }

    private static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, in clip: VideoState) -> Double {
        let width = Double(a.pixelsWide), height = Double(a.pixelsHigh)
        var total = 0.0
        for row in 1...12 {
            for column in 1...12 {
                let x = Int((clip.x + clip.width * Double(column) / 13) * width)
                let y = Int((clip.y + clip.height * Double(row) / 13) * height)
                guard let c = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let d = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return .infinity }
                total += abs(c.redComponent - d.redComponent) + abs(c.greenComponent - d.greenComponent) + abs(c.blueComponent - d.blueComponent)
            }
        }
        return total / (12 * 12 * 3)
    }

    private static func wait(_ duration: Double) async { try? await Task.sleep(for: .seconds(duration)) }
}
