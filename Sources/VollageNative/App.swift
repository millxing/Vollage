import AppKit
import UniformTypeIdentifiers
import SwiftUI

@main struct VollageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Vollage", for: UUID.self) { $request in
            NativeCanvas(request: request)
        }.defaultSize(width: 1320, height: 840).windowToolbarStyle(.unified).commands { CanvasCommands() }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppHub.models.allSatisfy({ $0.canClose() }) else { return .terminateCancel }
        Task { for id in AppHub.discardedIDs { await RecoveryStore.shared.remove(id) }; NSApp.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
    func application(_ application: NSApplication, open urls: [URL]) { for url in urls { AppHub.openProject(url) } }
}
enum AppHub {
    static var models: [CanvasModel] = []
    static var pending: [UUID: URL] = [:]
    static var recoveries: [UUID: Recovery] = [:]
    static var open: ((UUID) -> Void)?
    static var restored = false
    static var discardedIDs = Set<UUID>()
    static func openProject(_ url: URL) { let id = UUID(); pending[id] = url; open?(id) }
    static func chooseProject() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [UTType(exportedAs: "com.vollage.project"), UTType(filenameExtension: "vollage-native") ?? .json]
        if panel.runModal() == .OK { panel.urls.forEach(openProject) }
    }
    static func restoreOnce() async {
        guard !restored else { return }; restored = true
        for id in pending.keys { open?(id) }
        guard ProcessInfo.processInfo.environment["VOLLAGE_TEST_MEDIA"] == nil else { return }
        for recovery in await RecoveryStore.shared.all() {
            let all = recovery.state.videos + recovery.state.scenes.compactMap { $0 }.flatMap(\.videos)
            guard all.allSatisfy({ FileManager.default.fileExists(atPath: $0.playbackPath) }) else { models.first?.status = "Some recovery media is missing. Recovery files were retained."; continue }
            let id = UUID(); recoveries[id] = recovery; open?(id)
        }
    }
}
struct CanvasModelKey: FocusedValueKey { typealias Value = CanvasModel }
extension FocusedValues {
    var canvasModel: CanvasModel? { get { self[CanvasModelKey.self] } set { self[CanvasModelKey.self] = newValue } }
}
struct CanvasCommands: Commands {
    @FocusedValue(\.canvasModel) private var model
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Videos…") { model?.chooseVideos() }.keyboardShortcut("i")
            Button("Open Project…") { AppHub.chooseProject() }.keyboardShortcut("o")
            Button("Save Project") { model?.saveProject() }.keyboardShortcut("s")
            Button("Save Project As…") { model?.saveProject(copy: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model?.undo() }.keyboardShortcut("z")
            Button("Redo") { model?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandGroup(after: .pasteboard) {
            Button("Select All Videos") { model?.selectAll() }.keyboardShortcut("a")
            Button("Duplicate Videos") { model?.duplicate() }.keyboardShortcut("d")
        }
        CommandGroup(after: .toolbar) {
            Button("Toggle Right Sidebar") { model?.toggleSidebar() }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
        }
        CommandMenu("Canvas") {
            Button("Play / Pause All") { model?.togglePlayback() }
            Button("Arrange Grid") { model?.arrange() }
            Button("Shuffle Videos") { model?.shuffle() }
            Button("Toggle Clean View") { model?.performing.toggle() }
            Button("Leave Clean View") { model?.performing = false }.keyboardShortcut(.escape, modifiers: [])
            Button("Fullscreen") { model?.window?.toggleFullScreen(nil) }.keyboardShortcut("f", modifiers: [.command, .control])
            Divider()
            Button("Save Screenshot…") { model?.screenshot() }
            Button("Start / Stop Output Recording") { model?.toggleRecording() }
        }
        CommandMenu("Scenes") {
            ForEach(0..<9, id: \.self) { index in
                Button("Recall Scene \(index+1)") { model?.recallScene(index) }
                Button("Capture Scene \(index+1)") { model?.captureScene(index) }
            }
        }
        CommandGroup(replacing: .help) { Button("Vollage Help") { let alert = NSAlert(); alert.messageText = "Vollage"; alert.informativeText = "Shift-click selects multiple videos. Drag to move; drag a corner to resize.\n\nSpace: play/pause all · P/Escape: clean view · G: grid · Shift-G: shuffle · K: keep · Shift-K: lock position · H: PNG · V: MP4 output\n\n1–9: recall scene · Shift-1–9: capture scene\n\nPortable .vollage projects include original media and scenes. Motion is not supported."; alert.runModal() } }
    }
}
