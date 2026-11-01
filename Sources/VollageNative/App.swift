import AppKit
import SwiftUI

@main struct VollageNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("Vollage Native") {
            NativeCanvas().frame(minWidth: 800, minHeight: 520)
        }
        .defaultSize(width: 1200, height: 760)
        .windowToolbarStyle(.unified)
        .commands { CanvasCommands() }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct CanvasModelKey: FocusedValueKey { typealias Value = CanvasModel }
extension FocusedValues {
    var canvasModel: CanvasModel? {
        get { self[CanvasModelKey.self] }
        set { self[CanvasModelKey.self] = newValue }
    }
}
struct CanvasCommands: Commands {
    @FocusedValue(\.canvasModel) private var model
    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Add Videos…") { model?.chooseVideos() }.keyboardShortcut("i")
            Button("Open Native Project…") { model?.openProject() }.keyboardShortcut("o")
            Button("Save Native Project…") { model?.saveProject() }.keyboardShortcut("s")
        }
        CommandMenu("Canvas") {
            Button("Play / Pause All") { model?.togglePlayback() }.keyboardShortcut(" ", modifiers: [])
            Button("Arrange Grid") { model?.arrange() }.keyboardShortcut("g", modifiers: [])
            Button("Shuffle Videos") { model?.shuffle() }.keyboardShortcut("g", modifiers: [.shift])
            Button("Toggle Performance Mode") { model?.performing.toggle() }.keyboardShortcut("p", modifiers: [])
            Button("Leave Performance Mode") { model?.performing = false }.keyboardShortcut(.escape, modifiers: [])
        }
    }
}
