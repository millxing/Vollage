import SwiftUI
import AppKit

struct WindowBinding: NSViewRepresentable {
    let model: CanvasModel
    final class Coordinator: NSObject, NSWindowDelegate {
        let model: CanvasModel
        weak var original: (any NSWindowDelegate)?
        init(_ model: CanvasModel) { self.model = model }
        func bind(_ window: NSWindow) {
            model.window = window
            if window.delegate !== self { original = window.delegate; window.delegate = self }
            window.titlebarAppearsTransparent = model.performing || model.fullscreen
            window.backgroundColor = .windowBackgroundColor
            window.titleVisibility = (model.performing || model.fullscreen) ? .hidden : .visible
            window.toolbar?.isVisible = !model.performing && !model.fullscreen
            window.titlebarSeparatorStyle = .none
            window.styleMask.insert(.fullSizeContentView)
            window.title = model.title; window.isDocumentEdited = model.dirty
        }
        func windowWillEnterFullScreen(_ notification: Notification) {
            model.fullscreen = true
            if let window = notification.object as? NSWindow { bind(window) }
            original?.windowWillEnterFullScreen?(notification)
        }
        func windowDidExitFullScreen(_ notification: Notification) {
            model.fullscreen = false
            if let window = notification.object as? NSWindow { bind(window) }
            original?.windowDidExitFullScreen?(notification)
        }
        func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions) -> NSApplication.PresentationOptions {
            proposedOptions.union([.autoHideToolbar, .autoHideMenuBar, .autoHideDock])
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool { model.canClose() }
        func windowWillClose(_ notification: Notification) { model.close(); original?.windowWillClose?(notification) }
    }
    final class BindingView: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { attached?(window) } }
    }
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> BindingView {
        let view = BindingView(); view.attached = { [weak coordinator = context.coordinator] window in coordinator?.bind(window) }; return view
    }
    func updateNSView(_ view: BindingView, context: Context) { if let window = view.window { context.coordinator.bind(window) } }
}
