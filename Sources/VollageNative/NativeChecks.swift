import AppKit
import AVFoundation

enum NativeChecks {
    static var started = false
    static func runIfRequested(_ model: CanvasModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["VOLLAGE_TEST_MEDIA"], !started else { return }
        started = true
        let selftest = CommandLine.arguments.contains("--selftest")
        var failures = 0
        func check(_ condition: Bool, _ label: String) {
            let line = "\(condition ? "PASS" : "FAIL") \(label)\n"
            FileHandle.standardError.write(Data(line.utf8))
            if !condition { failures += 1 }
        }
        let urls = ["landscape.mp4", "portrait.mp4"].map { URL(fileURLWithPath: fixture).appendingPathComponent($0) }
        model.add(urls)
        try? await Task.sleep(for: .seconds(2))
        if selftest {
            check(model.clips.count == 2, "import two real videos")
            guard let first = model.clips.first else { exit(1) }
            check(model.clips.allSatisfy { $0.player.currentItem?.status == .readyToPlay }, "AVFoundation decodes both fixtures")
            let before = first.player.currentTime().seconds
            try? await Task.sleep(for: .milliseconds(250))
            check(abs(first.player.currentTime().seconds - before) > 0.05, "video time advances")
            model.togglePlayback()
            check(model.clips.allSatisfy { $0.player.rate == 0 }, "global pause stops every player")
            let pausedTime = first.player.currentTime().seconds
            try? await Task.sleep(for: .milliseconds(200))
            check(abs(first.player.currentTime().seconds - pausedTime) < 0.05, "pause holds current frame")
            first.muted = false; first.mirrored = true; first.speed = 0.5
            // UI disables speed while paused; restore pause after deliberately exercising its setter.
            first.player.pause()
            check(!first.player.isMuted, "mute control updates AVPlayer")
            first.x = 0.2; first.y = 0.3; first.locked = true
            model.arrange()
            check(first.x == 0.2 && first.y == 0.3, "grid preserves locked position")
            do {
                let data = try model.projectData()
                let file = URL(fileURLWithPath: "/tmp/vollage-native-fixtures/roundtrip.vollage-native")
                try data.write(to: file, options: .atomic)
                try model.loadProject(Data(contentsOf: file))
                check(model.clips.count == 2 && model.paused, "project restores videos and global pause")
                let restored = model.clips[0]
                check(restored.x == 0.2 && restored.y == 0.3 && restored.locked && restored.mirrored && !restored.muted && restored.speed == 0.5, "project restores placement and playback settings")
                check(model.clips.allSatisfy { $0.player.rate == 0 }, "loaded paused project stays paused")
                let previousIDs = model.clips.map(\.id)
                do { try model.loadProject(Data("invalid".utf8)); check(false, "invalid project rejected") }
                catch { check(model.clips.map(\.id) == previousIDs, "invalid project leaves canvas intact") }
                var missing = try JSONDecoder().decode(Project.self, from: data)
                missing.clips[0].path = "/tmp/vollage-missing-file.mp4"
                do { try model.loadProject(JSONEncoder().encode(missing)); check(false, "missing media rejected") }
                catch { check(model.clips.map(\.id) == previousIDs, "missing media leaves canvas intact") }
                model.folder = urls; model.count = 2; model.shuffle()
                check(model.clips.contains { $0.id == restored.id }, "shuffle preserves locked video")
                check(Set(model.clips.map(\.url)).count == model.clips.count, "shuffle avoids duplicate sources")
                model.togglePlayback()
                check(restored.player.rate == 0.5, "resume preserves playback speed")
                try? await Task.sleep(for: .seconds(5))
                check(restored.player.currentItem?.status == .readyToPlay && restored.looper.loopCount > 0, "AVPlayerLooper continues beyond source duration")
                model.remove(restored)
                check(!model.clips.contains { $0.id == restored.id } && restored.player.rate == 0, "remove stops player and removes clip")
                model.clips.forEach { $0.player.pause() }; model.clips = []; model.paused = false
                model.add(urls)
            } catch { check(false, "project round trip: \(error)") }
        }
        model.selection = model.clips.first?.id
        if let output = env["VOLLAGE_SNAPSHOTS"] {
            try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
            for mode in ["light", "dark"] {
                NSApp.appearance = NSAppearance(named: mode == "light" ? .aqua : .darkAqua)
                try? await Task.sleep(for: .seconds(1))
                capture("\(output)/canvas-\(mode).png", check: check)
            }
            model.performing = true
            try? await Task.sleep(for: .seconds(1))
            capture("\(output)/performance.png", check: check)
            model.performing = false
        }
        if selftest { exit(failures == 0 ? 0 : 1) }
    }
    static func capture(_ path: String, check: (Bool, String) -> Void) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { check(false, "window exists"); return }
        NSApp.activate(); window.makeKeyAndOrderFront(nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
        do { try process.run(); process.waitUntilExit(); check(process.terminationStatus == 0, "snapshot \(path)") }
        catch { check(false, "snapshot: \(error)") }
    }
}
