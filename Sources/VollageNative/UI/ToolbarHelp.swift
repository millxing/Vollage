import AppKit

// SwiftUI's toolbar hosting can drop Button.help on macOS 26. Set help on
// the public AppKit item and its host view as well; neither intercepts clicks.
enum ToolbarHelp {
    static let addVideos = "Add videos (⌘I)"
    static let playback = "Play or pause the composition (Space)"
    static let undo = "Undo (⌘Z)"
    static let shuffle = "Shuffle unlocked videos (⇧G)"
    static let output = "Save projects, PNG screenshots, or MP4 recordings"
    static let cleanView = "Hide controls (P); return with Escape"
    static let fullscreen = "Toggle fullscreen (Return)"
    static let settings = "Open Settings (⌘,)"
    static let sidebar = "Show or hide the right sidebar (⌘⇧\\)"

    static func text(for label: String) -> String? {
        switch label {
        case "Add Videos": addVideos
        case "Play All", "Pause All": playback
        case "Undo": undo
        case "Shuffle": shuffle
        case "Save and Output": output
        case "Clean View": cleanView
        case "Fullscreen": fullscreen
        case "Settings": settings
        case "Show Right Sidebar", "Hide Right Sidebar": sidebar
        default: nil
        }
    }

    static func install(in window: NSWindow) {
        for item in window.toolbar?.items ?? [] {
            guard let text = text(for: item.label) else { continue }
            if item.toolTip != text { item.toolTip = text }
            if let view = item.view {
                if view.toolTip != text { view.toolTip = text }
                view.setAccessibilityHelp(text)
            }
        }
    }
}
