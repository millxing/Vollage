import Foundation
import AVFoundation
import CryptoKit

actor MediaLibrary {
    static let shared = MediaLibrary()
    nonisolated static let extensions = Set(["mp4", "m4v", "mov", "mkv", "wmv", "flv", "avi", "webm"])
    nonisolated static var root: URL {
        if let value = ProcessInfo.processInfo.environment["VOLLAGE_DATA_ROOT"] { return URL(fileURLWithPath: value) }
        return URL.applicationSupportDirectory.appendingPathComponent("VollageNative", isDirectory: true)
    }
    nonisolated static var ffmpeg: String? { ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    nonisolated static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
    nonisolated static func run(_ arguments: [String]) async throws {
        guard let executable = ffmpeg else { throw VollageError.message("Install FFmpeg with Homebrew to convert unsupported video or record audio.") }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let code: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-nostdin", "-v", "error"] + arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = handle
            process.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard code == 0 else { throw VollageError.message("Media processing failed: " + String((try? String(contentsOf: log, encoding: .utf8))?.suffix(1000) ?? "Unknown error")) }
    }
    func files(in folder: URL) throws -> [URL] {
        guard let iterator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { throw VollageError.message("Cannot read this folder.") }
        return iterator.compactMap { $0 as? URL }.filter { Self.extensions.contains($0.pathExtension.lowercased()) && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }
    func prepare(_ url: URL) async throws -> VideoState {
        guard Self.extensions.contains(url.pathExtension.lowercased()) else { throw VollageError.message("Unsupported file: \(url.lastPathComponent)") }
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        var playback = url
        let asset = AVURLAsset(url: url)
        if !(try await asset.load(.isPlayable)) {
            let key = Self.digest("\(url.path):\(attrs[.size] ?? 0):\(attrs[.modificationDate] ?? "")")
            let directory = Self.root.appendingPathComponent("converted")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            playback = directory.appendingPathComponent(key + ".mp4")
            if !FileManager.default.fileExists(atPath: playback.path) {
                let temporary = directory.appendingPathComponent(UUID().uuidString + ".mp4")
                defer { try? FileManager.default.removeItem(at: temporary) }
                try await Self.run(["-i", url.path, "-map", "0:v:0", "-map", "0:a:0?", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2", "-c:a", "aac", "-y", temporary.path])
                try FileManager.default.moveItem(at: temporary, to: playback)
            }
        }
        let ready = AVURLAsset(url: playback)
        guard let track = try await ready.loadTracks(withMediaType: .video).first else { throw VollageError.message("No playable video in \(url.lastPathComponent)") }
        let size = try await track.load(.naturalSize), transform = try await track.load(.preferredTransform)
        let oriented = size.applying(transform)
        let ratio = abs(oriented.width / oriented.height)
        guard ratio.isFinite && ratio > 0 else { throw VollageError.message("Invalid video dimensions.") }
        var state = VideoState(path: url.path, sourcePath: url.path, name: url.lastPathComponent, playbackPath: playback.path)
        state.aspect = ratio
        state.orientation = [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty]
        return state
    }
    func rating(_ source: String) throws -> Int {
        let url = URL(fileURLWithPath: source)
        let file = url.deletingLastPathComponent().appendingPathComponent("vollage-ratings.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return 0 }
        let data = try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file))
        return data[url.lastPathComponent] ?? 0
    }
    func rate(_ source: String, value: Int) throws {
        guard (0...10).contains(value) else { throw VollageError.message("Rating must be Unrated or 1–10.") }
        let url = URL(fileURLWithPath: source)
        let file = url.deletingLastPathComponent().appendingPathComponent("vollage-ratings.json")
        var data = FileManager.default.fileExists(atPath: file.path) ? try JSONDecoder().decode([String: Int].self, from: Data(contentsOf: file)) : [:]
        data[url.lastPathComponent] = value == 0 ? nil : value
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(data).write(to: file, options: .atomic)
    }
    func audio(_ path: String) async throws -> Data? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { return nil }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw VollageError.message("Invalid audio duration.") }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let directory = Self.root.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appendingPathComponent(Self.digest("padded:\(path):\(attrs[.size] ?? 0):\(attrs[.modificationDate] ?? "")") + ".f32")
        if !FileManager.default.fileExists(atPath: output.path) {
            let temporary = directory.appendingPathComponent(UUID().uuidString + ".f32")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await Self.run(["-i", path, "-vn", "-af", "apad", "-t", String(duration), "-f", "f32le", "-ac", "2", "-ar", "48000", "-y", temporary.path])
            try FileManager.default.moveItem(at: temporary, to: output)
        }
        return try Data(contentsOf: output, options: .mappedIfSafe)
    }
}
