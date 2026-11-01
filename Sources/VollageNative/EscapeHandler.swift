import AppKit
import SwiftUI

/// Handle Escape even when the canvas has no focusable controls in performance mode.
struct EscapeHandler: NSViewRepresentable {
    var handle: () -> Bool
    final class KeyView: NSView {
        var handle: (() -> Bool)?
        var monitor: Any?
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event }
                let handled = MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                          window == NSApp.keyWindow, window.attachedSheet == nil,
                          self.handle?() == true else { return false }
                    return true
                }
                return handled ? nil : event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
    func makeNSView(context: Context) -> KeyView {
        let view = KeyView(); view.handle = handle; view.install(); return view
    }
    func updateNSView(_ view: KeyView, context: Context) { view.handle = handle }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }
}
