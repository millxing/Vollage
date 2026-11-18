import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

@Observable final class CanvasModel {
    let id = UUID()
    var clips: [Clip] = []
    var selectedIDs = Set<String>()
    var primaryID: String?
    var selected: Clip? { clips.first { $0.id == primaryID } }
    var selection: [Clip] { clips.filter { selectedIDs.contains($0.id) } }
    var document = DocumentState()
    static let sidebarWidth: CGFloat = 304
    var sidebarVisible = true
    var resizingOutput = false
    var performing = false
    var fullscreen = false
    var panel = "Video"
    var error: String?
    var status = ""
    var busy = false
    var dirty = false
    var projectURL: URL?
    var closeAfterSave = false
    var recoveryElapsed = 0.0
    var folder: [URL] = []
    var automatic = false
    var countdown = 30.0
    var now = 0.0
    var undoStack: [DocumentState] = []
    var redoStack: [DocumentState] = []
    var recording: OutputRecorder?
    var recordingStarted = Date()
    @ObservationIgnored var importing: Task<Void, Never>?
    @ObservationIgnored var recoveryTask: Task<Void, Never>?
    @ObservationIgnored var transaction: DocumentState?
    @ObservationIgnored var workspaceSize = CGSize(width: 1016, height: 788)
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored let compositor = Compositor()
    var paused: Bool { document.paused }
    var canEdit: Bool { !performing && !busy }
    var title: String { projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    func toggleSidebar() {
        let opening = !sidebarVisible
        guard let window, !performing, !window.styleMask.contains(.fullScreen) else {
            sidebarVisible = opening
            return
        }
        var frame = window.frame
        let minimumWidth: CGFloat = opening ? 960 : 656
        frame.size.width = max(minimumWidth, frame.width + (opening ? Self.sidebarWidth : -Self.sidebarWidth))
        if let screen = window.screen {
            let available = screen.visibleFrame
            frame.size.width = min(frame.width, available.width)
            // Keep the left edge fixed unless the expanded window would go offscreen.
            frame.origin.x = max(available.minX, min(frame.minX, available.maxX - frame.width))
        }
        sidebarVisible = opening
        window.minSize.width = minimumWidth
        window.setFrame(frame, display: true)
    }
    @discardableResult
    func exitPresentation() -> Bool {
        let isFullscreen = window?.styleMask.contains(.fullScreen) == true
        guard performing || isFullscreen else { return false }
        performing = false
        if isFullscreen { window?.toggleFullScreen(nil) }
        return true
    }
    func snapshot() -> DocumentState { var value = document; value.videos = clips.map { $0.snapshot() }; return value }
    func apply(_ state: DocumentState) {
        let old = Dictionary(uniqueKeysWithValues: clips.map { ($0.id, $0) })
        clips = state.videos.map { value in
            if let existing = old[value.id], existing.state.playbackPath == value.playbackPath {
                existing.globalPaused = state.paused; existing.state = value
                existing.seek(to: value.time)
                return existing
            }
            return Clip(value, globalPaused: state.paused)
        }
        let remaining = Set(clips.map(\.id)); old.values.filter { !remaining.contains($0.id) }.forEach { $0.player.pause() }
        let changedFolder = document.folderPath != state.folderPath
        automatic = state.autoShuffle ?? false; countdown = state.seconds
        document = state; selectedIDs.formIntersection(remaining)
        if changedFolder {
            folder = []
            Task { let values = (try? await MediaLibrary.shared.files(in: URL(fileURLWithPath: state.folderPath))) ?? []; if document.folderPath == state.folderPath { folder = values } }
        }
        if !remaining.contains(primaryID ?? "") { primaryID = selectedIDs.first }
        refreshRatings()
    }
    func checkpoint() { if transaction == nil { undoStack.append(snapshot()); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack = [] } }
    func changed() { dirty = true; window?.isDocumentEdited = true; scheduleRecovery() }
    func beginGesture() { guard transaction == nil else { return }; transaction = snapshot() }
    func endGesture() {
        guard let before = transaction else { return }; transaction = nil
        undoStack.append(before); if undoStack.count > 50 { undoStack.removeFirst() }; redoStack = []; changed()
    }
    func undo() { guard canEdit, let previous = undoStack.popLast() else { return }; redoStack.append(snapshot()); apply(previous); changed() }
    func redo() { guard canEdit, let next = redoStack.popLast() else { return }; undoStack.append(snapshot()); apply(next); changed() }
    func edit(_ body: (Clip) -> Void) { guard canEdit, !selection.isEmpty else { return }; checkpoint(); selection.forEach(body); changed() }
    func select(_ clip: Clip, extending: Bool = false) {
        guard !performing else { return }
        if extending { if !selectedIDs.insert(clip.id).inserted { selectedIDs.remove(clip.id) } } else { selectedIDs = [clip.id] }
        primaryID = selectedIDs.contains(clip.id) ? clip.id : selectedIDs.first
    }
    func selectAll() { guard canEdit else { return }; selectedIDs = Set(clips.map(\.id)); primaryID = clips.last?.id }
    func removeSelection() {
        guard canEdit else { return }; checkpoint()
        selection.forEach { $0.player.pause() }; clips.removeAll { selectedIDs.contains($0.id) }; selectedIDs = []; primaryID = nil; changed()
    }
    func clear() { guard canEdit else { return }; checkpoint(); clips.forEach { $0.player.pause() }; clips = []; selectedIDs = []; primaryID = nil; changed() }
    func duplicate(offset: Double = 0.1) {
        guard canEdit else { return }; checkpoint()
        let copies = selection.map { clip in var value = clip.snapshot(); value.id = UUID().uuidString; value.x += offset; value.y += offset; return Clip(value, globalPaused: paused) }
        clips += copies; selectedIDs = Set(copies.map(\.id)); primaryID = copies.last?.id; changed()
    }
    func layer(_ forward: Bool) {
        guard canEdit else { return }; checkpoint()
        let indices = forward ? Array(clips.indices.reversed()) : Array(clips.indices)
        for i in indices where selectedIDs.contains(clips[i].id) {
            let j = i + (forward ? 1 : -1)
            if clips.indices.contains(j), !selectedIDs.contains(clips[j].id) { clips.swapAt(i, j) }
        }; changed()
    }
    func togglePlayback() {
        guard !busy else { return }; checkpoint(); document.paused.toggle()
        clips.forEach { $0.globalPaused = paused; $0.sync() }; changed()
    }
    func toggleSelectedPlayback() {
        guard let clip = selected else { return }
        let pause = !clip.state.paused && clip.state.speed > 0
        edit { $0.state.paused = pause; if !pause && $0.state.speed == 0 { $0.state.speed = 1 } }
    }
    func seek(_ seconds: Double) {
        guard let clip = selected, canEdit else { return }
        checkpoint(); clip.seek(to: max(0, seconds)); changed()
    }
    func cancelImport() { importing?.cancel(); status = "Cancelling import…" }
    func add(_ urls: [URL]) { guard canEdit else { return }; importing = Task { await importVideos(urls) } }
    func importVideos(_ urls: [URL]) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        var ready: [VideoState] = []; var failures: [String] = []
        for (i, url) in urls.enumerated() {
            if Task.isCancelled { return }; status = "Preparing video \(i + 1) of \(urls.count)…"
            do { var value = try await MediaLibrary.shared.prepare(url); value.height = value.width * document.canvasWidth / document.canvasHeight / value.aspect; if let recording { try await recording.cacheAudio([value]) }; ready.append(value) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        guard !Task.isCancelled else { return }
        if !ready.isEmpty { checkpoint(); clips += ready.map { Clip($0, globalPaused: paused) }; arrange(recordHistory: false); changed(); refreshRatings() }
        status = ""
        if !failures.isEmpty { error = failures.joined(separator: "\n") }
    }
    func chooseVideos() {
        guard canEdit else { return }
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = MediaLibrary.extensions.compactMap { UTType(filenameExtension: $0) }
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func chooseFolder() {
        guard canEdit else { return }; let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importing = Task {
            do { let values = try await MediaLibrary.shared.files(in: url); checkpoint(); folder = values; document.folderPath = url.path; changed(); if clips.isEmpty { await shuffleNow() } }
            catch { self.error = error.localizedDescription }
        }
    }
    func changeCount(_ value: Int) {
        guard canEdit else { return }; beginGesture(); document.count = value
        if folder.isEmpty { endGesture() } else { importing = Task { await shuffleNow(); endGesture() } }
    }
    func shuffle() { guard !busy, !folder.isEmpty else { return }; importing = Task { await shuffleNow() } }
    func shuffleNow() async {
        guard !busy, !folder.isEmpty else { return }; busy = true; defer { busy = false; countdown = document.seconds }
        let retained = clips.filter { $0.state.pinned || $0.state.locked }
        let sources = Set(retained.map { $0.state.path }), current = Set(clips.map { $0.state.path })
        let available = folder.filter { !sources.contains($0.path) }.shuffled().sorted { !current.contains($0.path) && current.contains($1.path) }
        let needed = max(0, document.count - retained.count)
        var ready: [VideoState] = []; let slots = clips.filter { !$0.state.pinned && !$0.state.locked }
        for url in available where ready.count < needed {
            if Task.isCancelled { return }; status = "Preparing shuffle \(ready.count + 1) of \(needed)…"
            do {
                var value = try await MediaLibrary.shared.prepare(url)
                if ready.count < slots.count { let old = slots[ready.count].snapshot(); value.x = old.x; value.y = old.y; value.width = old.width; value.height = old.height; value.speed = old.speed; value.volume = old.volume; value.muted = old.muted; value.paused = old.paused; value.mirrored = old.mirrored; value.blend = old.blend; value.effectStack = old.effectStack }
                if let recording { try await recording.cacheAudio([value]) }
                ready.append(value)
            } catch { status = "Skipped \(url.lastPathComponent)" }
        }
        guard !Task.isCancelled else { return }
        if needed > 0 && ready.isEmpty { error = "No playable replacement videos were found. The composition was kept."; return }
        checkpoint()
        var replacements = ready.makeIterator(); var next: [Clip] = []
        for clip in clips {
            if clip.state.pinned || clip.state.locked { next.append(clip) }
            else { clip.player.pause(); if let value = replacements.next() { next.append(Clip(value, globalPaused: paused)) } }
        }
        while let value = replacements.next() { next.append(Clip(value, globalPaused: paused)) }
        clips = next; selectedIDs.formIntersection(Set(clips.map(\.id))); primaryID = selectedIDs.first
        arrange(recordHistory: false); changed(); refreshRatings(); status = "Shuffled \(ready.count) videos"
    }
    func tick(_ elapsed: Double) {
        now += elapsed
        recoveryElapsed += elapsed
        if dirty && recoveryElapsed > 15 { recoveryElapsed = 0; scheduleRecovery() }
        if automatic && !paused && !busy && NSApp.modalWindow == nil && !NSApp.isHidden { countdown -= elapsed; if countdown <= 0 { shuffle() } }
    }
    func refreshRatings() { Task { for clip in clips { do { clip.rating = try await MediaLibrary.shared.rating(clip.originalURL.path) } catch { status = error.localizedDescription } } } }
    func rate(_ value: Int) {
        guard selection.count == 1, let clip = selected else { return }
        Task { do { try await MediaLibrary.shared.rate(clip.originalURL.path, value: value); for model in AppHub.models { model.refreshRatings() } } catch { self.error = error.localizedDescription } }
    }
}
