import Foundation

actor ProjectStore {
    static let shared = ProjectStore()
    func save(_ state: DocumentState, to url: URL, embeddingMedia: Bool = false) throws {
        var paths: [String] = []
        var assets: [[String: Any]] = []
        func windows(_ values: [VideoState]) throws -> [[String: Any]] {
            try values.map { clip in
                // Old portable projects may only have their extracted media left.
                let path = !embeddingMedia && FileManager.default.fileExists(atPath: clip.sourcePath) ? clip.sourcePath : clip.path
                var index = paths.firstIndex(of: path)
                if index == nil {
                    guard FileManager.default.isReadableFile(atPath: path) else {
                        throw VollageError.message("Missing video: \(path). Restore it before saving this project.")
                    }
                    index = paths.count; paths.append(path)
                    if embeddingMedia {
                        let attrs = try FileManager.default.attributesOfItem(atPath: path)
                        assets.append(["name": clip.name, "sourcePath": clip.sourcePath, "size": (attrs[.size] as? NSNumber)?.uint64Value ?? 0])
                    } else {
                        let source = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
                        let directory = url.deletingLastPathComponent().standardizedFileURL.pathComponents
                        let common = zip(source, directory).prefix { $0 == $1 }.count
                        let relative = (Array(repeating: "..", count: directory.count - common) + source.dropFirst(common)).joined(separator: "/")
                        assets.append(["name": clip.name, "sourcePath": path, "relativePath": relative])
                    }
                }
                return ["uid": clip.id, "asset": index!, "x": clip.x * state.canvasWidth, "y": clip.y * state.canvasHeight,
                        "width": clip.width * state.canvasWidth, "height": clip.height * state.canvasHeight, "speed": clip.speed,
                        "volume": clip.volume, "time": clip.time, "muted": clip.muted, "paused": clip.paused, "mirrored": clip.mirrored,
                        "locked": clip.locked, "pinned": clip.pinned, "blend": clip.blend]
            }
        }
        let current = try windows(state.videos)
        let scenes: [Any] = try state.scenes.map { scene in
            guard let scene else { return NSNull() }
            var value: [String: Any] = ["name": scene.name, "windows": try windows(scene.videos), "globalPaused": scene.paused, "motion": NSNull()]
            if let data = scene.thumbnail { value["thumbnail"] = "data:image/png;base64," + data.base64EncodedString() }
            return value
        }
        let manifest: [String: Any] = ["version": embeddingMedia ? 5 : 6, "canvas": ["width": Int(state.canvasWidth), "height": Int(state.canvasHeight), "mode": state.fixedCanvas ? "fixed" : "window"], "windows": current, "assets": assets, "scenes": scenes, "globalPaused": state.paused, "activeScene": state.activeScene, "motion": NSNull(), "folder": ["path": state.folderPath, "count": state.count, "seconds": state.seconds, "auto": state.autoShuffle ?? false]]
        let json = try JSONSerialization.data(withJSONObject: manifest)
        guard json.count <= 64 * 1024 * 1024 else { throw VollageError.message("Project metadata is too large.") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).vollage")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var length = UInt32(json.count).littleEndian
        try output.write(contentsOf: Data("VOLLAGE1".utf8))
        try withUnsafeBytes(of: &length) { try output.write(contentsOf: Data($0)) }
        try output.write(contentsOf: json)
        for (index, path) in paths.enumerated() where embeddingMedia {
            let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? input.close() }
            var total: UInt64 = 0
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try output.write(contentsOf: chunk); total += UInt64(chunk.count) }
            guard total == (assets[index]["size"] as? UInt64) else { throw VollageError.message("Source changed while saving: \(path)") }
        }
        try output.synchronize(); try output.close()
        if FileManager.default.fileExists(atPath: url.path) { _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary) }
        else { try FileManager.default.moveItem(at: temporary, to: url) }
    }
    func load(_ url: URL) async throws -> (DocumentState, Bool) {
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        let header = try input.read(upToCount: 12) ?? Data()
        if String(data: header.prefix(8), encoding: .utf8) != "VOLLAGE1" { return (try await loadNative(url), false) }
        guard header.count == 12 else { throw VollageError.message("Incomplete project header.") }
        let length = header.dropFirst(8).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        guard length <= 64 * 1024 * 1024, let json = try input.read(upToCount: Int(length)), json.count == length,
              let data = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let version = data["version"] as? Int, [1, 4, 5, 6].contains(version),
              let assets = data["assets"] as? [[String: Any]], assets.count <= 10000 else { throw VollageError.message("Unsupported or damaged Vollage project.") }
        let size = try input.seekToEnd(); try input.seek(toOffset: UInt64(12 + length))
        var media: [VideoState] = []
        if version == 6 {
            guard size == UInt64(12 + length) else { throw VollageError.message("Unexpected media in linked project.") }
            for asset in assets {
                guard let path = asset["sourcePath"] as? String, path.hasPrefix("/"),
                      let name = asset["name"] as? String else { throw VollageError.message("Invalid video reference.") }
                let absolute = URL(fileURLWithPath: path)
                var candidates: [URL] = []
                if let relative = asset["relativePath"] as? String, !relative.hasPrefix("/"), !relative.isEmpty {
                    candidates.append(url.deletingLastPathComponent().appendingPathComponent(relative).standardizedFileURL)
                }
                candidates.append(absolute)
                guard let source = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }) else {
                    throw VollageError.message("Missing video: \(path). Restore the file or reconnect its drive, then reopen the project.")
                }
                var ready = try await MediaLibrary.shared.prepare(source)
                ready.name = name
                media.append(ready)
            }
        } else {
            var total = UInt64(12 + length)
            for asset in assets {
                guard let n = asset["size"] as? NSNumber, n.doubleValue >= 0, n.doubleValue.rounded() == n.doubleValue,
                      let name = asset["name"] as? String, MediaLibrary.extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()), n.uint64Value <= size - min(size, total) else { throw VollageError.message("Invalid embedded media.") }
                total += n.uint64Value
            }
            guard total == size else { throw VollageError.message("Project media length does not match its header.") }
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let root = MediaLibrary.root.appendingPathComponent("embedded/" + MediaLibrary.digest("\(url.path):\(size):\(attrs[.modificationDate] ?? "")"))
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for (index, asset) in assets.enumerated() {
                let name = URL(fileURLWithPath: asset["name"] as! String).lastPathComponent
                let output = root.appendingPathComponent("\(index)-\(name)")
                let count = (asset["size"] as! NSNumber).uint64Value
                let offset = try input.offset() // grid: ok binary file offset, not UI layout
                let existing = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.uint64Value
                if existing != count {
                    let temporary = root.appendingPathComponent(UUID().uuidString)
                    FileManager.default.createFile(atPath: temporary.path, contents: nil)
                    let target = try FileHandle(forWritingTo: temporary)
                    do {
                        var remaining = count
                        while remaining > 0 {
                            guard let chunk = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !chunk.isEmpty else { throw VollageError.message("Embedded media is truncated.") }
                            try target.write(contentsOf: chunk); remaining -= UInt64(chunk.count)
                        }
                        try target.close()
                        if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
                        try FileManager.default.moveItem(at: temporary, to: output)
                    } catch { try? target.close(); try? FileManager.default.removeItem(at: temporary); throw error }
                }
                try input.seek(toOffset: offset + count)
                var ready = try await MediaLibrary.shared.prepare(output)
                ready.name = name
                if let source = asset["sourcePath"] as? String, FileManager.default.fileExists(atPath: source) { ready.sourcePath = source }
                media.append(ready)
            }
        }
        let canvas = data["canvas"] as? [String: Any] ?? [:]
        let w = (canvas["width"] as? Double) ?? 1920, h = (canvas["height"] as? Double) ?? 1080
        guard w >= 1, h >= 1, w <= 7680, h <= 7680 else { throw VollageError.message("Invalid canvas dimensions.") }
        func decode(_ value: Any?) throws -> [VideoState] {
            guard let values = value as? [[String: Any]], values.count <= 1000 else { throw VollageError.message("Invalid video list.") }
            var ids = Set<String>()
            return try values.map { v in
                guard let index = v["asset"] as? Int, media.indices.contains(index) else { throw VollageError.message("Missing video asset.") }
                var clip = media[index]; clip.id = (v["uid"] as? String) ?? UUID().uuidString
                guard ids.insert(clip.id).inserted else { throw VollageError.message("Duplicate video identity.") }
                func number(_ key: String, _ fallback: Double) throws -> Double {
                    let n = v[key] as? Double ?? fallback
                    guard n.isFinite else { throw VollageError.message("Invalid \(key).") }; return n
                }
                clip.x = try number("x", 0) / w; clip.y = try number("y", 0) / h
                clip.width = try number("width", 320) / w; clip.height = try number("height", 180) / h
                clip.speed = Float(try number("speed", 1)); clip.volume = Float(try number("volume", 1)); clip.time = try number("time", 0)
                clip.muted = v["muted"] as? Bool ?? false; clip.paused = v["paused"] as? Bool ?? false
                clip.mirrored = v["mirrored"] as? Bool ?? false; clip.locked = v["locked"] as? Bool ?? false
                clip.pinned = v["pinned"] as? Bool ?? (version < 5 && clip.locked)
                clip.blend = v["blend"] as? String ?? "normal"
                guard clip.width > 0, clip.height > 0, clip.width * w <= 100000, clip.height * h <= 100000, (0...16).contains(clip.speed), (0...1).contains(clip.volume), clip.time >= 0, ["normal", "screen", "multiply", "difference", "overlay"].contains(clip.blend) else { throw VollageError.message("Invalid video settings.") }
                return clip
            }
        }
        var result = DocumentState()
        result.canvasWidth = w; result.canvasHeight = h; result.fixedCanvas = canvas["mode"] as? String == "fixed"
        result.videos = try decode(data["windows"]); result.paused = data["globalPaused"] as? Bool ?? false
        if let scenes = data["scenes"] as? [Any] {
            guard scenes.count == 9 else { throw VollageError.message("Expected nine scene slots.") }
            result.scenes = try scenes.map { value in
                guard let scene = value as? [String: Any] else { return nil }
                let thumbnail = (scene["thumbnail"] as? String)?.split(separator: ",", maxSplits: 1).last.flatMap { Data(base64Encoded: String($0)) }
                return SceneState(name: String((scene["name"] as? String ?? "Scene").prefix(100)), videos: try decode(scene["windows"]), paused: scene["globalPaused"] as? Bool ?? false, thumbnail: thumbnail)
            }
        }
        if let folder = data["folder"] as? [String: Any] {
            result.autoShuffle = folder["auto"] as? Bool ?? false; result.folderPath = folder["path"] as? String ?? ""; result.count = min(100, max(1, folder["count"] as? Int ?? 5)); result.seconds = min(3600, max(2, folder["seconds"] as? Double ?? 30))
        }
        result.activeScene = data["activeScene"] as? Int ?? -1
        let hasMotion = (data["motion"] is [String: Any]) || (data["scenes"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }.contains { $0["motion"] is [String: Any] }
        return (result, hasMotion)
    }
    private func loadNative(_ url: URL) async throws -> DocumentState {
        let data = try Data(contentsOf: url)
        if let state = try? JSONDecoder().decode(DocumentState.self, from: data) {
            guard state.version == 2, state.scenes.count == 9, state.canvasWidth.isFinite, state.canvasHeight.isFinite,
                  (1...7680).contains(state.canvasWidth), (1...7680).contains(state.canvasHeight), (1...100).contains(state.count), (2...3600).contains(state.seconds) else { throw VollageError.message("Invalid native project settings.") }
            for values in [state.videos] + state.scenes.compactMap({ $0?.videos }) {
                guard values.count <= 1000, Set(values.map(\.id)).count == values.count else { throw VollageError.message("Invalid video identities.") }
                for clip in values {
                    guard [clip.x, clip.y, clip.width, clip.height, clip.aspect, clip.time].allSatisfy(\.isFinite), clip.width > 0, clip.height > 0, clip.aspect > 0, clip.time >= 0,
                          (0...16).contains(clip.speed), (0...1).contains(clip.volume), FileManager.default.fileExists(atPath: clip.playbackPath) else { throw VollageError.message("Invalid or missing video in native project.") }
                }
            }
            return state
        }
        guard let old = try JSONSerialization.jsonObject(with: data) as? [String: Any], old["version"] as? Int == 1, let clips = old["clips"] as? [[String: Any]] else { throw VollageError.message("Not a Vollage project.") }
        var document = DocumentState(); document.paused = old["paused"] as? Bool ?? false
        for item in clips {
            guard let path = item["path"] as? String else { throw VollageError.message("Missing source path.") }
            var clip = try await MediaLibrary.shared.prepare(URL(fileURLWithPath: path))
            clip.width = item["width"] as? Double ?? 0.3; clip.height = clip.width
            clip.x = (item["x"] as? Double ?? 0.5) - clip.width / 2; clip.y = (item["y"] as? Double ?? 0.5) - clip.height / 2
            clip.muted = item["muted"] as? Bool ?? true; clip.speed = (item["speed"] as? NSNumber)?.floatValue ?? 1
            clip.mirrored = item["mirrored"] as? Bool ?? false; clip.locked = item["locked"] as? Bool ?? false
            document.videos.append(clip)
        }
        return document
    }
}
