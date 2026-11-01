import SwiftUI
import UniformTypeIdentifiers

extension CanvasModel {
    func captureScene(_ index: Int) {
        guard canEdit else { return }; checkpoint()
        let image = compositor.png(clips: clips, size: CGSize(width: 240, height: 240 * document.canvasHeight / document.canvasWidth))
        document.scenes[index] = SceneState(name: document.scenes[index]?.name ?? "Scene \(index + 1)", videos: clips.map { $0.snapshot() }, paused: paused, thumbnail: image)
        document.activeScene = index; changed()
    }
    func recallScene(_ index: Int) {
        guard !busy, let scene = document.scenes[index] else { return }; checkpoint()
        var next = snapshot(); next.videos = scene.videos; next.paused = scene.paused; next.activeScene = index; next.gridActive = false
        apply(next); changed(); countdown = document.seconds
    }
    func renameScene(_ index: Int, _ name: String) { guard canEdit else { return }; checkpoint(); document.scenes[index]?.name = String(name.prefix(100)); changed() }
    func saveProject(copy: Bool = false) {
        guard !busy else { return }
        var destination = projectURL
        if destination == nil || copy {
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(exportedAs: "com.vollage.project")]; panel.nameFieldStringValue = title + ".vollage"
            guard panel.runModal() == .OK else { return }; destination = panel.url
        }
        guard let destination else { return }; busy = true; status = "Saving portable project…"
        let state = snapshot()
        importing = Task {
            defer { busy = false; if closeAfterSave && !dirty { closeAfterSave = false; window?.performClose(nil) } }
            do { try await ProjectStore.shared.save(state, to: destination); projectURL = destination; dirty = false; window?.isDocumentEdited = false; window?.title = title; window?.representedURL = destination; await RecoveryStore.shared.remove(id); status = "Saved \(destination.lastPathComponent)" }
            catch { self.error = error.localizedDescription }
        }
    }
    func openProject() { AppHub.chooseProject() }
    func load(_ url: URL) async {
        guard !busy else { return }; busy = true; status = "Opening project…"; defer { busy = false }
        do {
            let (state, motion) = try await ProjectStore.shared.load(url)
            apply(state); projectURL = url; dirty = false; undoStack = []; redoStack = []; automatic = false
            window?.isDocumentEdited = false; window?.title = title; window?.representedURL = url
            if !state.folderPath.isEmpty { folder = (try? await MediaLibrary.shared.files(in: URL(fileURLWithPath: state.folderPath))) ?? [] }
            automatic = state.autoShuffle == true && !folder.isEmpty; countdown = state.seconds
            status = motion ? "Opened project. Motion is not supported and will be omitted when saving." : "Opened \(url.lastPathComponent)"
        } catch { self.error = error.localizedDescription; status = "Project could not be opened." }
    }
    func scheduleRecovery() {
        guard ProcessInfo.processInfo.environment["VOLLAGE_TEST_MEDIA"] == nil else { return }
        recoveryTask?.cancel()
        recoveryTask = Task {
            try? await Task.sleep(for: .milliseconds(500)); guard !Task.isCancelled else { return }
            do { try await RecoveryStore.shared.write(id, state: snapshot(), project: projectURL) } catch { status = "Recovery could not be saved: \(error.localizedDescription)" }
        }
    }
    func canClose() -> Bool {
        if recording != nil { let alert = NSAlert(); alert.messageText = "Stop output recording before closing this window."; alert.runModal(); return false }
        if busy { let alert = NSAlert(); alert.messageText = "Wait for the current operation or cancel the import before closing."; alert.runModal(); return false }
        guard dirty else { return true }
        let alert = NSAlert(); alert.messageText = "Save changes to “\(title)”?"; alert.informativeText = "Your changes will be lost if you discard them."
        alert.addButton(withTitle: "Save…"); alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: closeAfterSave = true; saveProject(); if !busy { closeAfterSave = false }; return false
        case .alertSecondButtonReturn: recoveryTask?.cancel(); dirty = false; AppHub.discardedIDs.insert(id); Task { await RecoveryStore.shared.remove(id) }; return true
        default: return false
        }
    }
    func close() { cancelImport(); recoveryTask?.cancel(); clips.forEach { $0.player.pause() }; AppHub.models.removeAll { $0 === self } }
    func screenshot() {
        guard !busy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = title + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = compositor.png(clips: clips, size: CGSize(width: document.canvasWidth, height: document.canvasHeight)) else { error = "A video frame is not ready yet. Try again after playback starts."; return }
        do { try data.write(to: url, options: .atomic); status = "Screenshot saved" } catch { self.error = error.localizedDescription }
    }
    func toggleRecording() {
        if let recorder = recording {
            guard !recorder.isFinishing else { return }
            recorder.isFinishing = true
            Task { do { try await recorder.finish(); status = "Output recording saved" } catch { self.error = error.localizedDescription }; recording = nil }
            return
        }
        guard !busy else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.mpeg4Movie]; panel.nameFieldStringValue = title + ".mp4"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true; status = "Preparing output audio…"
        Task {
            defer { busy = false }
            do {
                let recorder = try OutputRecorder(url: url, size: CGSize(width: document.canvasWidth, height: document.canvasHeight))
                let sources = clips.map(\.state) + document.scenes.compactMap { $0 }.flatMap(\.videos)
                try await recorder.prepareAudio(sources)
                recording = recorder; recordingStarted = Date(); status = "Recording output"
            } catch { self.error = error.localizedDescription }
        }
    }
}
nonisolated struct Recovery: Codable, Sendable { var id: UUID; var state: DocumentState; var project: URL? }
actor RecoveryStore {
    static let shared = RecoveryStore()
    private var root: URL { MediaLibrary.root.appendingPathComponent("recovery") }
    func write(_ id: UUID, state: DocumentState, project: URL?) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(Recovery(id: id, state: state, project: project)).write(to: root.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
    }
    func remove(_ id: UUID) { try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString + ".json")) }
    func all() -> [Recovery] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).compactMap { url in (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Recovery.self, from: $0) } }
    }
}
