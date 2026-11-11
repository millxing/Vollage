import AppKit
import AVFoundation

// Runs against synthetic media and a separate data root, never the user's projects.
enum NativeChecks {
    static var started = false
    static func runIfRequested(_ model: CanvasModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["VOLLAGE_TEST_MEDIA"], !started else { return }; started = true
        guard env["VOLLAGE_DATA_ROOT"]?.hasPrefix("/tmp/") == true else { print("FAIL isolated test data root required"); exit(1) }
        var failures = 0
        func check(_ condition: Bool, _ name: String) {
            FileHandle.standardError.write(Data("\(condition ? "PASS" : "FAIL") \(name)\n".utf8)); if !condition { failures += 1 }
        }
        func wait(_ seconds: Double = 0.4) async { try? await Task.sleep(for: .seconds(seconds)) }
        let root = URL(fileURLWithPath: fixture)
        func checkToolbarHelp() {
            let items = (model.window?.toolbar?.items ?? []).filter { ToolbarHelp.text(for: $0.label) != nil }
            check(items.count == 8, "all eight toolbar actions are present")
            for item in items {
                let expected = ToolbarHelp.text(for: item.label)
                check(item.toolTip == expected && item.view?.toolTip == expected, "native hover help: \(item.label)")
            }
        }
        if env["VOLLAGE_TOOLTIP_CHECK"] == "1" {
            await wait(1); checkToolbarHelp()
            model.togglePlayback(); await wait(); checkToolbarHelp()
            model.toggleSidebar(); await wait(); checkToolbarHelp()
            model.toggleSidebar(); model.togglePlayback(); await wait(); checkToolbarHelp()
            exit(failures == 0 ? 0 : 1)
        }
        if env["VOLLAGE_REVIEW_ONLY"] == "1", let directory = env["VOLLAGE_SNAPSHOTS"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            await model.importVideos([root.appendingPathComponent("red.mp4"), root.appendingPathComponent("blue.mp4")])
            model.folder = [root.appendingPathComponent("red.mp4"), root.appendingPathComponent("blue.mp4")]
            model.document.folderPath = root.path
            model.captureScene(0); model.renameScene(0, "First Scene")
            if env["VOLLAGE_REVIEW_WAIT_ACTIVE"] == "1" {
                model.status = "Review ready — click the canvas to begin capture"
                while !NSApp.isActive { await wait(0.2) }
                model.status = ""
            }
            await ReviewEvidence.capture(model, directory: directory, check: check)
            exit(failures == 0 ? 0 : 1)
        }
        if env["VOLLAGE_UI_ONLY"] == "1" {
            await model.importVideos([root.appendingPathComponent("red.mp4"), root.appendingPathComponent("portrait.mp4")])
            model.folder = [root.appendingPathComponent("red.mp4"), root.appendingPathComponent("blue.mp4"), root.appendingPathComponent("portrait.mp4")]
            model.document.folderPath = root.path
            if env["VOLLAGE_UI_SIZE"] == "minimum" { model.window?.setContentSize(NSSize(width: 960, height: 588)) }
            model.status = "Synthetic media for UI testing"; model.dirty = false
            return
        }
        if let roundtrip = env["VOLLAGE_ROUNDTRIP"] {
            await model.load(URL(fileURLWithPath: roundtrip))
            check(model.clips.count == 2 && model.document.scenes[0]?.name == "First Scene", "Electron-saved portable project opens natively")
            check(model.clips.allSatisfy { FileManager.default.fileExists(atPath: $0.state.path) }, "embedded media extracted")
            for version in [1, 4] {
                let (browser, _) = try! await ProjectStore.shared.load(root.appendingPathComponent("browser-\(version).vollage"))
                check(browser.videos.count == 2, "browser v\(version) project opens natively")
            }
            exit(failures == 0 ? 0 : 1)
        }
        await model.importVideos([root.appendingPathComponent("red.mp4"), root.appendingPathComponent("blue.mp4")])
        await wait(1)
        checkToolbarHelp()
        if let window = model.window {
            let originalFrame = window.frame
            let originalCanvas = model.workspaceSize
            model.toggleSidebar(); await wait()
            check(!model.sidebarVisible && abs(window.frame.width - (originalFrame.width - CanvasModel.sidebarWidth)) < 2, "closing sidebar shrinks window outward")
            check(abs(model.workspaceSize.width - originalCanvas.width) < 2, "closing sidebar preserves canvas width")
            model.toggleSidebar(); await wait()
            check(model.sidebarVisible && abs(window.frame.width - originalFrame.width) < 2, "opening sidebar restores window width")
            check(abs(model.workspaceSize.width - originalCanvas.width) < 2, "opening sidebar preserves canvas width")
        }
        if let surface = model.window?.contentView.flatMap({ findCanvas(in: $0) }) {
            let before = model.snapshot()
            model.toggleOutputResize()
            let frame = surface.canvas
            let start = CGPoint(x: frame.maxX, y: frame.midY)
            let end = CGPoint(x: start.x-80, y: start.y)
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: surface.convert(point, to: nil), modifierFlags: [], timestamp: 0, windowNumber: model.window!.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            surface.mouseDown(with: mouse(.leftMouseDown, start))
            surface.mouseDragged(with: mouse(.leftMouseDragged, end))
            surface.mouseUp(with: mouse(.leftMouseUp, end))
            check(model.document.fixedCanvas && model.document.canvasWidth < before.canvasWidth && model.document.canvasHeight == before.canvasHeight, "dragging output edge changes only output width")
            let old = before.videos[0], resized = model.clips[0].state
            check(abs(old.width*before.canvasWidth-resized.width*model.document.canvasWidth) < 0.01 && abs(old.x*before.canvasWidth-resized.x*model.document.canvasWidth) < 0.01, "output resize preserves video pixels and placement")
            let resizedWidth = model.document.canvasWidth
            model.workspaceChanged(CGSize(width: 900, height: 600))
            check(model.document.canvasWidth == resizedWidth, "fixed output is independent of workspace size")
            model.undo(); check(model.document.canvasWidth == before.canvasWidth, "undo restores output frame")
            model.redo(); check(model.document.canvasWidth == resizedWidth, "redo restores resized frame")
            let cornerStart = surface.canvas
            let cornerPoint = CGPoint(x: cornerStart.maxX, y: cornerStart.maxY)
            surface.mouseDown(with: mouse(.leftMouseDown, cornerPoint))
            surface.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: cornerPoint.x-40, y: cornerPoint.y-40)))
            surface.mouseUp(with: mouse(.leftMouseUp, cornerPoint))
            check(model.document.canvasWidth < resizedWidth && model.document.canvasHeight < before.canvasHeight, "dragging output corner changes both dimensions")
            if let png = model.compositor.png(clips: model.clips, size: CGSize(width: model.document.canvasWidth, height: model.document.canvasHeight)), let image = NSBitmapImageRep(data: png) {
                check(image.pixelsWide == Int(model.document.canvasWidth) && image.pixelsHigh == Int(model.document.canvasHeight), "export uses resized output dimensions")
            } else { check(false, "resized output PNG renders") }
            model.apply(before); model.resizingOutput = false
            model.workspaceSize = surface.bounds.size
        }
        check(model.clips.count == 2, "import real H.264 videos")
        guard model.clips.count == 2 else { exit(1) }
        check(model.clips.allSatisfy { $0.player.currentItem?.status == .readyToPlay }, "AVFoundation ready for playback")
        let first = model.clips[0], second = model.clips[1]
        let before = first.player.currentTime().seconds; await wait()
        check(abs(first.player.currentTime().seconds - before) > 0.1, "video time advances")
        model.select(first); model.select(second, extending: true)
        check(model.selection.count == 2, "multi-selection extends")
        model.edit { $0.state.muted = false; $0.state.volume = 0.4; $0.state.speed = 0.5; $0.state.mirrored = true }
        check(model.clips.allSatisfy { !$0.player.isMuted && $0.player.volume == 0.4 && $0.player.rate == 0.5 && $0.state.mirrored }, "batch playback edits reach players")
        model.undo(); check(model.clips.allSatisfy { $0.state.muted && !$0.state.mirrored }, "undo restores grouped edit")
        model.redo(); check(model.clips.allSatisfy { !$0.state.muted && $0.state.mirrored }, "redo reapplies grouped edit")
        model.togglePlayback(); await wait(0.2); let pausedTime = first.player.currentTime().seconds; await wait()
        check(abs(first.player.currentTime().seconds - pausedTime) < 0.05 && model.clips.allSatisfy { $0.player.rate == 0 }, "global pause holds frames")
        model.select(first); model.edit { $0.state.paused = true }
        model.togglePlayback(); check(first.player.rate == 0 && second.player.rate == 0.5, "global resume preserves individual pause")
        model.seek(0.7); await wait(); check(abs(first.player.currentTime().seconds - 0.7) < 0.1, "seek paused video")
        model.edit { $0.state.paused = false; $0.state.speed = 0 }
        model.toggleSelectedPlayback()
        check(first.state.speed == 1 && first.player.rate == 1, "Play on a still video resumes at normal speed")
        model.duplicate(); check(model.clips.count == 3 && Set(model.clips.map(\.id)).count == 3, "duplicate uses independent identity")
        model.removeSelection(); check(model.clips.count == 2, "delete selected videos")
        model.select(first); model.edit { $0.state.locked = true; $0.state.x = 0; $0.state.y = 0; $0.state.width = 0.2; $0.state.height = 0.2 }
        model.arrange()
        check(first.state.x == 0 && first.state.width == 0.2, "grid preserves position locks")
        let rect1 = CGRect(x: first.state.x, y: first.state.y, width: first.state.width, height: first.state.height)
        let rect2 = CGRect(x: second.state.x, y: second.state.y, width: second.state.width, height: second.state.height)
        check(!rect1.intersects(rect2), "grid avoids locked rectangles")
        let actualAspect = second.state.width * model.document.canvasWidth / (second.state.height * model.document.canvasHeight)
        check(abs(actualAspect - second.state.aspect) < 0.01, "grid respects source aspect ratio")
        model.edit { $0.state.locked = false; $0.state.pinned = true }
        model.folder = [root.appendingPathComponent("red.mp4"), root.appendingPathComponent("blue.mp4"), root.appendingPathComponent("portrait.mp4")]
        model.document.count = 2; await model.shuffleNow()
        check(model.clips.contains { $0.id == first.id } && model.clips.count == 2, "shuffle keeps pinned source")
        check(Set(model.clips.map { $0.state.path }).count == 2, "shuffle avoids duplicate files")
        model.document.count = 1; await model.shuffleNow(); check(model.clips.count == 1 && model.clips[0].id == first.id, "count reduction respects retained video")
        model.document.count = 2; await model.shuffleNow()
        model.automatic = true; model.countdown = 0.1; model.document.paused = true; model.tick(0.2)
        check(model.countdown == 0.1, "automatic shuffle waits during global pause")
        model.document.paused = false
        let beforeAuto = Set(model.clips.map(\.id)); model.countdown = 0; model.tick(0.1)
        await wait(0.3)
        for _ in 0..<50 where model.busy { await wait(0.1) }
        model.automatic = false
        check(Set(model.clips.map(\.id)) != beforeAuto, "automatic shuffle performs replacements")
        model.captureScene(0); model.renameScene(0, "First Scene")
        let savedSceneIDs = model.clips.map(\.id); model.clear(); check(model.clips.isEmpty, "clear canvas")
        model.recallScene(0); check(model.clips.map(\.id) == savedSceneIDs, "scene recall restores identities and composition")
        model.undo(); check(model.clips.isEmpty && model.document.scenes[0] != nil, "undo scene recall")
        model.redo(); await wait(1)
        do {
            try await MediaLibrary.shared.rate(first.originalURL.path, value: 8)
            check(try await MediaLibrary.shared.rating(first.originalURL.path) == 8, "rating sidecar round trip")
            try await MediaLibrary.shared.rate(first.originalURL.path, value: 0)
            check(try await MediaLibrary.shared.rating(first.originalURL.path) == 0, "unrated removes sidecar score")
            let rotated = Clip(try await MediaLibrary.shared.prepare(root.appendingPathComponent("rotated.mp4")), globalPaused: false)
            var rotatedFrame = rotated.frame()
            for _ in 0..<40 where rotatedFrame == nil { await wait(0.05); rotatedFrame = rotated.frame() }
            check(rotated.state.aspect < 1 && rotatedFrame != nil && abs(rotatedFrame!.extent.width / rotatedFrame!.extent.height - rotated.state.aspect) < 0.01, "rotation metadata matches rendered orientation: \(String(describing: rotatedFrame?.extent)) / \(rotated.state.aspect)")
            rotated.player.pause()
            let converted = try await MediaLibrary.shared.prepare(root.appendingPathComponent("legacy.wmv"))
            check(converted.playbackPath != converted.path && converted.path.hasSuffix(".wmv"), "unsupported codec converts without replacing original")
            let convertedAgain = try await MediaLibrary.shared.prepare(root.appendingPathComponent("legacy.wmv"))
            check(convertedAgain.playbackPath == converted.playbackPath, "conversion cache reused")
            let linked = root.appendingPathComponent("linked.vollage")
            var linkedState = model.snapshot()
            linkedState.videos = [try await MediaLibrary.shared.prepare(root.appendingPathComponent("red.mp4"))]
            linkedState.videos[0].time = 0.75; linkedState.videos[0].volume = 0.4
            linkedState.scenes[1] = SceneState(name: "Scene-only media", videos: [converted], paused: true)
            try await ProjectStore.shared.save(linkedState, to: linked)
            let linkedBytes = try Data(contentsOf: linked)
            let linkedLength = linkedBytes.dropFirst(8).prefix(4).enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
            let linkedManifest = try JSONSerialization.jsonObject(with: linkedBytes.dropFirst(12)) as! [String: Any]
            let linkedAssets = linkedManifest["assets"] as! [[String: Any]]
            check(linkedBytes.count == linkedLength + 12 && linkedManifest["version"] as? Int == 6 && linkedAssets.allSatisfy { $0["size"] == nil }, "normal save contains metadata only, with no embedded media")
            check(Set(linkedAssets.compactMap { $0["sourcePath"] as? String }).count == linkedAssets.count, "linked media deduplicated across scenes")
            let reopened = try await ProjectStore.shared.load(linked).0
            check(reopened.videos == linkedState.videos && reopened.scenes == linkedState.scenes, "linked project restores video settings and all scenes")
            check(reopened.scenes[1]?.videos[0].path == converted.path && reopened.scenes[1]?.videos[0].playbackPath == converted.playbackPath, "linked scene-only media uses original and conversion cache")
            let relocated = root.appendingPathComponent("relocated")
            try FileManager.default.createDirectory(at: relocated, withIntermediateDirectories: true)
            let relocatedProject = relocated.appendingPathComponent("linked.vollage")
            try FileManager.default.copyItem(at: linked, to: relocatedProject)
            check(try await ProjectStore.shared.load(relocatedProject).0.videos[0].path == linkedState.videos[0].path, "project moved alone resolves absolute source path")
            // Move every referenced video alongside the project, leaving old absolute paths unavailable.
            var relocatedSources: [(URL, URL)] = []
            do {
                for asset in linkedAssets {
                    let source = URL(fileURLWithPath: asset["sourcePath"] as! String)
                    let target = relocated.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.moveItem(at: source, to: target)
                    relocatedSources.append((source, target))
                }
                let movedState = try await ProjectStore.shared.load(relocatedProject).0
                check(movedState.videos[0].path == relocated.appendingPathComponent("red.mp4").path && movedState.scenes[1]?.videos[0].path == relocated.appendingPathComponent("legacy.wmv").path, "project and media moved together resolve relative paths")
                let beforeMissing = model.document
                let beforeClips = model.clips.map(ObjectIdentifier.init)
                let beforeURL = model.projectURL
                await model.load(linked)
                check(model.error?.contains("Missing video:") == true && model.document == beforeMissing && model.clips.map(ObjectIdentifier.init) == beforeClips && model.projectURL == beforeURL, "missing linked media explains failure and preserves current document")
                model.error = nil
                for (source, target) in relocatedSources { try FileManager.default.moveItem(at: target, to: source) }
                relocatedSources = []
            } catch {
                for (source, target) in relocatedSources { try? FileManager.default.moveItem(at: target, to: source) }
                throw error
            }
            try FileManager.default.removeItem(at: relocatedProject)
            // Re-saving an existing large project replaces it with linked metadata.
            try await ProjectStore.shared.save(linkedState, to: linked, embeddingMedia: true)
            let embeddedSize = try Data(contentsOf: linked).count
            let embeddedState = try await ProjectStore.shared.load(linked).0
            try await ProjectStore.shared.save(embeddedState, to: linked)
            let resaved = try await ProjectStore.shared.load(linked).0
            check(try Data(contentsOf: linked).count < embeddedSize && resaved.videos.map(\.path) == linkedState.videos.map(\.path), "re-saving embedded project shrinks it and references originals")
            let project = root.appendingPathComponent("native-export.vollage")
            try await ProjectStore.shared.save(model.snapshot(), to: project, embeddingMedia: true)
            let original = root.appendingPathComponent("red.mp4"), moved = root.appendingPathComponent("red-hidden.mp4")
            try FileManager.default.moveItem(at: original, to: moved)
            let loaded: DocumentState
            do {
                loaded = try await ProjectStore.shared.load(project).0
                let cacheLinked = root.appendingPathComponent("cache-linked.vollage")
                try await ProjectStore.shared.save(loaded, to: cacheLinked)
                let cacheLoaded = try await ProjectStore.shared.load(cacheLinked).0
                check(cacheLoaded.videos.count == loaded.videos.count && cacheLoaded.scenes[0]?.name == "First Scene", "old embedded project can save and reopen links when originals are unavailable")
                try FileManager.default.moveItem(at: moved, to: original)
            }
            catch { try? FileManager.default.moveItem(at: moved, to: original); throw error }
            check(loaded.videos.count == 2, "portable project opens with original source absent")
            check(loaded.videos.count == 2 && loaded.scenes[0]?.name == "First Scene", "portable project restores scenes and media")
            check(loaded.videos[0].pinned && loaded.videos[0].mirrored, "portable project restores flags")
            let old = model.clips.map(\.id)
            let broken = root.appendingPathComponent("broken.vollage"); try Data("VOLLAGE1broken".utf8).write(to: broken)
            await model.load(broken); check(model.clips.map(\.id) == old && model.error != nil, "invalid project preserves current composition"); model.error = nil
            try await RecoveryStore.shared.write(model.id, state: model.snapshot(), project: project)
            check(await RecoveryStore.shared.all().contains { $0.id == model.id }, "recovery document persists")
            await RecoveryStore.shared.remove(model.id)
            check(!(await RecoveryStore.shared.all().contains { $0.id == model.id }), "recovery discarded independently")
            // Two full-frame solid sources provide a deterministic blend oracle.
            let red = try await MediaLibrary.shared.prepare(root.appendingPathComponent("red.mp4"))
            let blue = try await MediaLibrary.shared.prepare(root.appendingPathComponent("blue.mp4"))
            var state = DocumentState(); state.canvasWidth = 640; state.canvasHeight = 360; state.fixedCanvas = true
            state.videos = [red, blue].map { value in var c = value; c.x = 0; c.y = 0; c.width = 1; c.height = 1; c.muted = false; return c }
            model.apply(state); await wait(1)
            for blend in ["normal", "screen", "multiply", "difference", "overlay"] {
                model.clips[1].state.blend = blend; await wait(0.1)
                let data = model.compositor.png(clips: model.clips, size: CGSize(width: 640, height: 360))!
                try data.write(to: root.appendingPathComponent("blend-\(blend).png"))
                let image = NSBitmapImageRep(data: data)!, color = image.colorAt(x: 320, y: 180)!.usingColorSpace(.deviceRGB)!
                let ok: Bool
                switch blend {
                case "normal": ok = color.blueComponent > 0.7 && color.redComponent < 0.2
                case "screen", "difference": ok = color.redComponent > 0.7 && color.blueComponent > 0.7
                case "multiply": ok = color.redComponent < 0.2 && color.blueComponent < 0.2
                default: ok = color.redComponent > 0.7 && color.blueComponent < 0.2
                }; check(ok, "\(blend) blend exported correctly")
            }
            model.clips[1].state.blend = "screen"
            let shortAudio = try await MediaLibrary.shared.audio(root.appendingPathComponent("short-audio.mp4").path)!
            let silentTail = shortAudio.withUnsafeBytes { bytes in bytes.bindMemory(to: Float.self).suffix(48000).allSatisfy { abs($0) < 0.0001 } }
            check(shortAudio.count >= 48000 * 2 * 2 * 4 && silentTail, "short audio is padded with silence to video duration")
            let recorder = try OutputRecorder(url: root.appendingPathComponent("output.mp4"), size: CGSize(width: 640, height: 360))
            try await recorder.prepareAudio(model.clips.map(\.state)); model.recording = recorder
            await wait(0.6); let framesBeforeBusy = recorder.frames
            model.busy = true; await wait(0.5); model.busy = false
            check(recorder.frames > framesBeforeBusy + 5, "recording continues during background preparation")
            await wait(1.1); model.recording = nil; try await recorder.finish()
            let asset = AVURLAsset(url: root.appendingPathComponent("output.mp4"))
            let duration = try await asset.load(.duration).seconds
            check(duration > 1.5 && duration < 3.5, "MP4 duration follows real time")
            check(try await asset.loadTracks(withMediaType: .audio).count == 1, "MP4 contains mixed audio track")
            check(try await asset.loadTracks(withMediaType: .video).count == 1, "MP4 contains composed video track")
            await wait(2); check(model.clips.allSatisfy { $0.looper.loopCount > 0 }, "video loop continues past source duration")
            model.apply(loaded); model.status = ""; model.document.folderPath = root.path; model.folder = [root.appendingPathComponent("red.mp4"), root.appendingPathComponent("blue.mp4")]
            model.select(model.clips[0]); await wait(0.5)
        } catch { check(false, "integration: \(error.localizedDescription)") }
        if let directory = env["VOLLAGE_SNAPSHOTS"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for panel in ["Video", "Layers", "Scenes", "Setup"] {
                    model.panel = panel; await wait(0.4); await capture("\(directory)/\(panel.lowercased())-\(mode).png", model, check)
                }
            }
            model.panel = "Setup"; model.resizingOutput = true
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                await wait(); await capture("\(directory)/output-frame-\(mode).png", model, check)
            }
            model.resizingOutput = false
            if env["VOLLAGE_REVIEW"] == "1" { await ReviewEvidence.capture(model, directory: directory, check: check) }
            model.performing = true; await wait(); await capture("\(directory)/clean.png", model, check); model.performing = false
        }
        if CommandLine.arguments.contains("--selftest") { exit(failures == 0 ? 0 : 1) }
    }
    static func findCanvas(in view: NSView) -> CanvasView? {
        if let canvas = view as? CanvasView { return canvas }
        return view.subviews.lazy.compactMap { findCanvas(in: $0) }.first
    }
    static func capture(_ path: String, _ model: CanvasModel, _ check: (Bool, String) -> Void) async {
        guard let window = model.window else { check(false, "window exists"); return }
        NSApp.unhide(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(300))
        if window.isKeyWindow && NSApp.isActive { check(true, "snapshot has active key window") }
        else { FileHandle.standardError.write(Data("UNVERIFIED inactive window: \(URL(fileURLWithPath: path).lastPathComponent) — layout evidence only\n".utf8)) }
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        do { try process.run(); process.waitUntilExit(); check(process.terminationStatus == 0, "snapshot \(URL(fileURLWithPath: path).lastPathComponent)") } catch { check(false, "snapshot failed") }
    }
}
