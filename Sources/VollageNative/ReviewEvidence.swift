import AppKit
import AVFoundation

// Opt-in UI review fixtures, restricted to NativeChecks' isolated synthetic-media run.
enum ReviewEvidence {
    static func capture(_ model: CanvasModel, directory: String, check: (Bool, String) -> Void) async {
        guard let window = model.window else { return }
        func wait() async { try? await Task.sleep(for: .milliseconds(400)) }
        func shot(_ name: String) async {
            FileHandle.standardError.write(Data("VIEWPORT \(name): \(Int(window.frame.width)) × \(Int(window.frame.height)) points\n".utf8))
            await NativeChecks.capture("\(directory)/\(name).png", model, check)
        }
        func canvas(in view: NSView) -> CanvasView? {
            if let canvas = view as? CanvasView { return canvas }
            return view.subviews.compactMap { canvas(in: $0) }.first
        }
        let original = model.snapshot()
        model.performing = false
        model.clips.forEach { $0.state.locked = false }
        model.document.fixedCanvas = false
        window.setContentSize(NSSize(width: 1320, height: 840))
        await wait(); model.arrange(recordHistory: false)
        model.select(model.clips[0])
        for size in ["default", "minimum"] {
            window.setContentSize(size == "default" ? NSSize(width: 1320, height: 840) : NSSize(width: 960, height: 640))
            await wait()
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                for panel in ["Video", "Layers", "Scenes", "Setup"] {
                    model.panel = panel; await wait(); await shot("\(size)-\(panel.lowercased())-\(mode)")
                }
            }
        }
        window.setContentSize(NSSize(width: 1100, height: 720)); model.panel = "Video"; await wait(); await shot("intermediate-video")
        window.setContentSize(NSSize(width: 1320, height: 840)); await wait()
        model.panel = "Video"; model.select(model.clips[0]); await wait()
        await shot("timeline-a"); try? await Task.sleep(for: .milliseconds(500)); await shot("timeline-b")
        let before = model.clips.map(\.state)
        let canvasSize = CGSize(width: model.document.canvasWidth, height: model.document.canvasHeight)
        await shot("clean-before")
        model.performing = true; await wait(); await shot("clean-during")
        check(model.clips.map(\.state) == before && model.document.canvasWidth == canvasSize.width && model.document.canvasHeight == canvasSize.height, "clean view preserves exact composition geometry and aspect ratio")
        window.setContentSize(NSSize(width: 1100, height: 720)); await wait(); await shot("clean-resized")
        check(model.clips.map(\.state) == before && model.document.canvasWidth == canvasSize.width && model.document.canvasHeight == canvasSize.height, "resizing clean view preserves exact composition geometry and aspect ratio")
        window.setContentSize(NSSize(width: 1320, height: 840)); await wait()
        _ = model.exitPresentation(); await wait(); await shot("clean-after")
        check(!model.performing && model.clips.map(\.state) == before, "leaving clean view restores editing without geometry changes")
        let selectedBeforeSingle = model.snapshot()
        model.select(model.clips[1]); model.removeSelection(); model.select(model.clips[0]); model.panel = "Video"
        for mode in ["light", "dark"] {
            NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
            await wait(); await shot("single-video-\(mode)")
        }
        model.apply(selectedBeforeSingle)
        model.selectAll(); await shot("multi-selection")
        model.selectedIDs = []; model.primaryID = nil; await shot("empty-selection")
        model.clear(); await shot("empty-composition"); model.undo()
        model.select(model.clips[0])
        let name = model.clips[0].state.name
        model.clips[0].state.name = "A very long video filename — 東京の夜と海の記録 — extended cut 2026 final version.mp4"
        model.panel = "Video"; await wait(); await shot("long-video")
        model.panel = "Layers"; await wait(); await shot("long-layers")
        model.clips[0].state.name = name
        model.renameScene(0, "A very long scene name — sunset, city lights and ocean")
        model.panel = "Scenes"; await wait(); await shot("long-scene")
        let path = model.document.folderPath
        model.document.folderPath = "/Volumes/Media Archive/Long folder names and international footage/東京/Projects/Collage Source Videos 2026"
        model.panel = "Setup"; await wait(); await shot("long-folder")
        model.document.folderPath = path
        model.status = "Preparing video 1 of 2…"; model.busy = true; await shot("busy"); model.busy = false; model.status = ""
        // The real output is tested above; capture its live badge while recording synthetic frames.
        do {
            let recorder = try OutputRecorder(url: URL(fileURLWithPath: "\(directory)/review-output.mp4"), size: CGSize(width: 640, height: 360))
            try await recorder.prepareAudio(model.clips.map(\.state))
            model.recordingStarted = Date(); model.recording = recorder
            await shot("recording"); model.performing = true; await wait(); await shot("recording-clean")
            model.performing = false; model.recording = nil; try await recorder.finish()
        } catch { check(false, "review recording: \(error.localizedDescription)") }
        if let surface = window.contentView.flatMap({ canvas(in: $0) }) {
            window.makeFirstResponder(surface)
            let oldPaused = model.paused
            func key(_ code: UInt16, _ characters: String) {
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) { NSApp.sendEvent(event) }
            }
            model.select(model.clips[0])
            let x = model.clips[0].state.x
            key(124, "")
            check(abs(model.clips[0].state.x - x - 1 / model.document.canvasWidth) < 0.00001, "canvas arrow key moves selected video by one output pixel")
            model.clips[0].state.locked = true
            let lockedX = model.clips[0].state.x; key(124, "")
            check(model.clips[0].state.x == lockedX, "canvas arrow key preserves position lock")
            model.clips[0].state.locked = false
            key(49, " ")
            check(model.paused != oldPaused, "Space on focused canvas toggles playback via actual window event")
            let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
            window.contentView?.addSubview(field); window.makeFirstResponder(field)
            let paused = model.paused, count = model.clips.count
            key(15, "r"); key(18, "1"); key(49, " ")
            check(model.paused == paused && model.clips.count == count && field.stringValue.contains("r1"), "text entry receives shortcut characters without canvas actions")
            field.removeFromSuperview()
            let button = NSButton(title: "Keyboard test", target: nil, action: nil)
            window.contentView?.addSubview(button); window.makeFirstResponder(button)
            key(49, " ")
            check(model.paused == paused, "Space on focused native button does not toggle canvas playback")
            button.removeFromSuperview(); window.makeFirstResponder(surface)
            let children = surface.accessibilityChildren() as? [CanvasClipAccessibility] ?? []
            check(children.count == model.clips.count && children.first?.accessibilityLabel() == model.clips.first?.state.name, "canvas accessibility exposes named clip buttons")
            model.selectedIDs = []; model.primaryID = nil
            check(children.first?.accessibilityPerformPress() == true && model.selected?.id == model.clips.first?.id, "canvas accessibility press selects its video")
            let dump = children.map { "\($0.accessibilityRole()?.rawValue ?? "?") | \($0.accessibilityLabel() ?? "?") | \(String(describing: $0.accessibilityValue()))" }.joined(separator: "\n")
            try? dump.write(toFile: "\(directory)/canvas-accessibility.txt", atomically: true, encoding: .utf8)
        } else { check(false, "canvas found for keyboard and AX checks") }
        model.apply(original); model.select(model.clips[0]); model.panel = "Video"; await wait()
    }
}
