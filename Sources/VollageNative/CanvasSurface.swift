import SwiftUI
import AppKit

struct CanvasSurface: NSViewRepresentable {
    let model: CanvasModel
    func makeNSView(context: Context) -> CanvasView { CanvasView(model) }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.accessibleClips.removeAll { element in !model.clips.contains { $0 === element.clip } }
        view.needsDisplay = true
    }
    static func dismantleNSView(_ view: CanvasView, coordinator: ()) { view.timer?.invalidate(); view.stopKeys() }
}
final class CanvasView: NSView {
    let model: CanvasModel
    var timer: Timer?
    var keyMonitor: Any?
    var accessibleClips: [CanvasClipAccessibility] = []
    var previousTick = ProcessInfo.processInfo.systemUptime
    var anchor = CGPoint.zero
    var originals: [String: VideoState] = [:]
    var resizeCorner: Int?
    var originalBounds = CGRect.zero
    var dragging = false
    var duplicateOnDrag = false
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(_ model: CanvasModel) {
        self.model = model; super.init(frame: .zero)
        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.window, window == NSApp.keyWindow,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      window.firstResponder === self else { return false }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }
        timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                self.model.tick(min(0.2, now - self.previousTick)); self.previousTick = now
                if let recorder = self.model.recording, !recorder.isFinishing {
                    do { try recorder.append(self.model.clips, compositor: self.model.compositor) }
                    catch { self.model.error = error.localizedDescription; self.model.toggleRecording() }
                }
                self.needsDisplay = true
            }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Initial canvas focus enables editing shortcuts. Inspector controls keep their own keys.
        if let window, window.firstResponder == nil || window.firstResponder === window.contentView {
            window.makeFirstResponder(self)
        }
    }
    func stopKeys() { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }; keyMonitor = nil }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    var canvas: CGRect {
        guard model.document.fixedCanvas || model.performing else { return bounds }
        let ratio = model.document.canvasWidth / model.document.canvasHeight
        let width = min(bounds.width, bounds.height * ratio), height = min(bounds.height, bounds.width / ratio)
        return CGRect(x: (bounds.width-width)/2, y: (bounds.height-height)/2, width: width, height: height)
    }
    override func layout() { super.layout(); model.workspaceChanged(bounds.size) }
    func rect(_ state: VideoState) -> CGRect { CGRect(x: canvas.minX + state.x * canvas.width, y: canvas.minY + state.y * canvas.height, width: state.width * canvas.width, height: state.height * canvas.height) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        guard canvas.width > 0, canvas.height > 0 else { return }
        let size = CGSize(width: canvas.width.rounded(), height: canvas.height.rounded())
        let image = model.compositor.image(clips: model.clips, size: size)
        if let cg = model.compositor.context.createCGImage(image, from: CGRect(origin: .zero, size: size)) {
            NSImage(cgImage: cg, size: size).draw(in: canvas, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        guard !model.performing else { return }
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: canvas).addClip()
        for clip in model.selection {
            let box = rect(clip.state)
            (clip.state.locked ? NSColor.systemOrange : NSColor.controlAccentColor).setStroke()
            let border = NSBezierPath(rect: box); border.lineWidth = 2
            if clip.state.locked { border.setLineDash([4, 4], count: 2, phase: 0) }
            border.stroke()
            if !clip.state.locked {
                NSColor.controlAccentColor.setFill()
                for point in corners(box) { CGRect(x: point.x-4, y: point.y-4, width: 8, height: 8).fill() }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    func corners(_ box: CGRect) -> [CGPoint] { [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY)] }
    func hit(_ point: CGPoint) -> Clip? { model.clips.reversed().first { rect($0.state).contains(point) } }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); guard model.canEdit else { return }
        duplicateOnDrag = event.modifierFlags.contains(.option)
        anchor = convert(event.locationInWindow, from: nil); resizeCorner = nil; dragging = false
        // Corner hits have priority over overlapping video content.
        for clip in model.selection where !clip.state.locked {
            if let corner = corners(rect(clip.state)).firstIndex(where: { hypot($0.x-anchor.x, $0.y-anchor.y) < 10 }) { resizeCorner = corner; break }
        }
        if resizeCorner == nil {
            guard let clip = hit(anchor) else { model.selectedIDs = []; model.primaryID = nil; return }
            if event.modifierFlags.contains(.shift) { model.select(clip, extending: true) }
            else if !model.selectedIDs.contains(clip.id) { model.select(clip) }
            else { model.primaryID = clip.id }
        }
        originals = Dictionary(uniqueKeysWithValues: model.selection.filter { !$0.state.locked }.map { ($0.id, $0.state) })
        originalBounds = originals.values.map(rect).reduce(CGRect.null) { $0.union($1) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard model.canEdit, !originals.isEmpty else { return }
        if !dragging {
            model.beginGesture()
            if duplicateOnDrag && resizeCorner == nil {
                model.duplicate(offset: 0)
                originals = Dictionary(uniqueKeysWithValues: model.selection.filter { !$0.state.locked }.map { ($0.id, $0.state) })
            }
            dragging = true; model.document.gridActive = false
        }
        let point = convert(event.locationInWindow, from: nil)
        if let corner = resizeCorner {
            let pivot = corners(originalBounds)[3-corner], start = corners(originalBounds)[corner]
            let dx = start.x-pivot.x, dy = start.y-pivot.y
            let scale = max(0.05, min(20, ((point.x-pivot.x)*dx+(point.y-pivot.y)*dy) / max(1, dx*dx+dy*dy)))
            for clip in model.selection { guard let old = originals[clip.id] else { continue }
                clip.state.x = (pivot.x-canvas.minX)/canvas.width + (old.x-(pivot.x-canvas.minX)/canvas.width)*scale
                clip.state.y = (pivot.y-canvas.minY)/canvas.height + (old.y-(pivot.y-canvas.minY)/canvas.height)*scale
                clip.state.width = old.width*scale; clip.state.height = old.height*scale
            }
        } else {
            for clip in model.selection { guard let old = originals[clip.id] else { continue }; clip.state.x = old.x+(point.x-anchor.x)/canvas.width; clip.state.y = old.y+(point.y-anchor.y)/canvas.height }
        }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { if dragging { model.endGesture() }; dragging = false; originals = [:] }
    override func keyDown(with event: NSEvent) {
        if handleKey(event) { return }; super.keyDown(with: event)
    }
    func handleKey(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command), !event.modifierFlags.contains(.control) else { return false }
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let shift = event.modifierFlags.contains(.shift)
        if event.keyCode == 53 { return model.exitPresentation() }
        if key == " " { model.togglePlayback(); return true }
        if key == "p" { model.performing.toggle(); return true }
        if key == "h" { model.screenshot(); return true }
        if key == "v" { model.toggleRecording(); return true }
        if event.keyCode == 36 { window?.toggleFullScreen(nil); return true }
        let numberKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        if let number = Int(key) ?? (shift ? numberKeys[event.keyCode] : nil), (1...9).contains(number) { if shift { model.captureScene(number-1) } else { model.recallScene(number-1) }; return true }
        if key == "g", shift { model.shuffle(); return true }
        guard model.canEdit else { return false }
        if event.keyCode == 51 || event.keyCode == 117 { model.removeSelection(); return true }
        if [123, 124, 125, 126].contains(event.keyCode), !model.selection.isEmpty {
            let step = shift ? 10.0 : 1.0
            let dx = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            model.edit { clip in
                guard !clip.state.locked else { return }
                clip.state.x += dx / model.document.canvasWidth
                clip.state.y += dy / model.document.canvasHeight
                model.document.gridActive = false
            }
            return true
        }
        switch key {
        case "g": model.arrange()
        case "k": if shift { let flag = !(model.selected?.state.locked ?? false); model.edit { $0.state.locked = flag } } else { let flag = !(model.selected?.state.pinned ?? false); model.edit { $0.state.pinned = flag } }
        case "n": let flag = !(model.selected?.state.muted ?? false); model.edit { $0.state.muted = flag }
        case "m": model.edit { $0.state.mirrored.toggle() }
        case "c": model.duplicate()
        case "d", "\u{7f}", "\u{8}": model.removeSelection()
        case "+", "=": model.edit { $0.state.speed = min(16, $0.state.speed + 0.25) }
        case "-": model.edit { $0.state.speed = max(0, $0.state.speed - 0.25) }
        case "[": model.edit { $0.state.volume = max(0, $0.state.volume - 0.1) }
        case "]": model.edit { $0.state.volume = min(1, $0.state.volume + 0.1) }
        case "a": model.layer(true)
        case "b": model.layer(false)
        case "z": model.document.gridActive = false; model.edit { if !$0.state.locked { $0.state.width *= 2; $0.state.height *= 2 } }
        case "u": model.undo()
        case "y": model.redo()
        case "o": model.chooseVideos()
        case "l": model.openProject()
        case "s": model.saveProject()
        case "r": model.clear()
        case "q": window?.performClose(nil)
        default: return false
        }; return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard model.canEdit else { return nil }
        if let clip = hit(convert(event.locationInWindow, from: nil)), !model.selectedIDs.contains(clip.id) { model.select(clip) }
        let menu = NSMenu()
        for (title, action) in [("Play / Pause", "play"), (model.selected?.state.muted == true ? "Unmute" : "Mute", "mute"), ("Mirror", "mirror"), ("Keep Video", "keep"), ("Lock Position", "lock"), ("Duplicate", "duplicate"), ("Delete", "delete"), ("Bring Forward", "forward"), ("Send Backward", "back"), ("Open in Default Video Player", "open"), ("Reveal in Finder", "reveal")] {
            let item = NSMenuItem(title: title, action: #selector(contextAction(_:)), keyEquivalent: ""); item.target = self; item.representedObject = action
            if action == "keep" { item.state = model.selected?.state.pinned == true ? .on : .off }
            if action == "lock" { item.state = model.selected?.state.locked == true ? .on : .off }
            menu.addItem(item)
        }
        let rating = NSMenuItem(title: "Rating", action: nil, keyEquivalent: ""); let ratings = NSMenu()
        for value in 0...10 { let item = NSMenuItem(title: value == 0 ? "Unrated" : String(value), action: #selector(rate(_:)), keyEquivalent: ""); item.target = self; item.tag = value; item.isEnabled = model.selection.count == 1; ratings.addItem(item) }
        rating.submenu = ratings; menu.addItem(rating); return menu
    }
    @objc func rate(_ item: NSMenuItem) { model.rate(item.tag) }
    @objc func contextAction(_ item: NSMenuItem) {
        switch item.representedObject as? String {
        case "play": model.toggleSelectedPlayback()
        case "mute": let flag = !(model.selected?.state.muted ?? false); model.edit { $0.state.muted = flag }
        case "mirror": model.edit { $0.state.mirrored.toggle() }
        case "keep": let flag = !(model.selected?.state.pinned ?? false); model.edit { $0.state.pinned = flag }
        case "lock": let flag = !(model.selected?.state.locked ?? false); model.edit { $0.state.locked = flag }
        case "duplicate": model.duplicate()
        case "delete": model.removeSelection()
        case "forward": model.layer(true)
        case "back": model.layer(false)
        case "open": if let clip = model.selected { NSWorkspace.shared.open(clip.originalURL) }
        case "reveal": if let clip = model.selected { NSWorkspace.shared.activateFileViewerSelecting([clip.originalURL]) }
        default: break
        }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Composition canvas" }
    override func accessibilityHelp() -> String? { "Select videos here or in Layers. Arrow keys move the selection; Shift moves ten pixels. Use the Video inspector for playback, appearance and placement." }
    override func accessibilityChildren() -> [Any]? {
        let existing = Dictionary(uniqueKeysWithValues: accessibleClips.map { ($0.clip.id, $0) })
        accessibleClips = model.clips.map { clip in
            let element = existing[clip.id].flatMap { $0.clip === clip ? $0 : nil } ?? CanvasClipAccessibility(clip: clip, canvas: self)
            element.update(canvas: self)
            return element
        }
        return accessibleClips
    }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { model.canEdit ? .copy : [] }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard model.canEdit, let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return false }
        model.add(urls); return true
    }
}

// Expose each composited video to assistive technology; drawing alone creates no AX objects.
@MainActor final class CanvasClipAccessibility: NSAccessibilityElement {
    let clip: Clip
    nonisolated let pressAction: @MainActor @Sendable () -> Bool
    nonisolated override init() { fatalError("Use init(clip:canvas:)") }
    init(clip: Clip, canvas: CanvasView) {
        self.clip = clip
        pressAction = { [weak canvas, weak clip] in
            guard let canvas, let clip, canvas.model.canEdit else { return false }
            canvas.model.select(clip)
            canvas.window?.makeFirstResponder(canvas)
            canvas.needsDisplay = true
            return true
        }
        super.init()
        setAccessibilityElement(true)
        setAccessibilityParent(canvas)
        setAccessibilityRole(.button)
        update(canvas: canvas)
    }
    func update(canvas: CanvasView) {
        setAccessibilityEnabled(canvas.model.canEdit)
        setAccessibilityLabel(clip.state.name)
        setAccessibilityValue("\(canvas.model.selectedIDs.contains(clip.id) ? "Selected" : "Not selected")\(clip.state.locked ? ", position locked" : "")\(clip.state.pinned ? ", kept during shuffle" : "")")
        if let window = canvas.window {
            setAccessibilityFrame(window.convertToScreen(canvas.convert(canvas.rect(clip.state), to: nil)))
        }
    }
    nonisolated override func accessibilityPerformPress() -> Bool {
        // AppKit delivers accessibility actions on the main thread. Capture only a Sendable callback.
        let action = pressAction
        return MainActor.assumeIsolated { action() }
    }
}
