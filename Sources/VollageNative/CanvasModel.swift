import SwiftUI
import AVKit
import UniformTypeIdentifiers

@Observable final class CanvasModel {
    var clips: [Clip] = []
    var selection: UUID?
    var paused = false
    var performing = false
    var folder: [URL] = []
    var count = 5
    var error: String?
    var selected: Clip? { clips.first { $0.id == selection } }
    func add(_ urls: [URL]) {
        for url in urls where ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) {
            let clip = Clip(url); if paused { clip.player.pause() }; clips.append(clip)
        }
        arrange()
    }
    func arrange() {
        let movable = clips.filter { !$0.locked }
        let columns = max(1, Int(ceil(sqrt(Double(movable.count)))))
        let rows = max(1, Int(ceil(Double(movable.count) / Double(columns))))
        for (i, clip) in movable.enumerated() {
            clip.width = 0.94 / Double(max(columns, rows))
            clip.x = (Double(i % columns) + 0.5) / Double(columns)
            clip.y = (Double(i / columns) + 0.5) / Double(rows)
        }
    }
    func chooseVideos() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = (FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])?.allObjects as? [URL] ?? []).filter { ["mp4", "mov", "m4v"].contains($0.pathExtension.lowercased()) }
        if clips.isEmpty { shuffle() }
    }
    func shuffle() {
        guard !folder.isEmpty else { return }
        for clip in clips where !clip.locked { clip.player.pause() }
        clips.removeAll { !$0.locked }
        add(Array(folder.filter { url in !clips.contains { $0.url == url } }.shuffled().prefix(max(0, count - clips.count))))
    }
    func saveProject() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Untitled.vollage-native"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try projectData().write(to: url, options: .atomic) } catch { self.error = error.localizedDescription }
    }
    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "vollage-native") ?? .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try loadProject(Data(contentsOf: url)) } catch { self.error = "Could not open the native project. Check its format and that the source videos still exist. " + error.localizedDescription }
    }

    func togglePlayback() {
        paused.toggle()
        for clip in clips { if paused { clip.player.pause() } else { clip.player.rate = clip.speed } }
    }
    func remove(_ clip: Clip) {
        clip.player.pause()
        clips.removeAll { $0.id == clip.id }
        selection = nil
    }
    func projectData() throws -> Data {
        try JSONEncoder().encode(Project(clips: clips.map { ClipRecord(path: $0.url.path, x: $0.x, y: $0.y, width: $0.width, muted: $0.muted, speed: $0.speed, mirrored: $0.mirrored, locked: $0.locked) }, paused: paused))
    }
    func loadProject(_ data: Data) throws {
        let project = try JSONDecoder().decode(Project.self, from: data)
        guard project.version == 1 else { throw CocoaError(.fileReadUnknown) }
        guard project.clips.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) && $0.x.isFinite && $0.y.isFinite && $0.width >= 0.05 && $0.width <= 1 && $0.speed >= 0 && $0.speed <= 4 }) else { throw CocoaError(.fileReadCorruptFile) }
        let replacement = project.clips.map { record in
            let clip = Clip(URL(fileURLWithPath: record.path)); clip.x = record.x; clip.y = record.y; clip.width = record.width; clip.muted = record.muted; clip.speed = record.speed; clip.mirrored = record.mirrored; clip.locked = record.locked
            if project.paused { clip.player.pause() }; return clip
        }
        clips.forEach { $0.player.pause() }
        clips = replacement; paused = project.paused; selection = nil
    }
}
struct Project: Codable {
    var version = 1
    var clips: [ClipRecord]
    var paused: Bool
}
