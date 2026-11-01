import SwiftUI
import AppKit

struct InspectorView: View {
    @Bindable var model: CanvasModel
    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("VOLLAGE").font(.headline).tracking(3); Spacer(); Text("\(model.clips.count) videos").font(.caption).foregroundStyle(.secondary) }
            Picker("Panel", selection: $model.panel) { ForEach(["Video", "Layers", "Scenes", "Setup"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).labelsHidden()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.panel {
                    case "Video": video
                    case "Layers": layers
                    case "Scenes": scenes
                    default: setup
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
            }
        }.padding(16).background(.background)
    }
    func toggle(_ title: String, _ path: WritableKeyPath<VideoState, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { model.selected?.state[keyPath: path] ?? false }, set: { value in model.edit { $0.state[keyPath: path] = value } }))
    }
    func slider(_ title: String, _ path: WritableKeyPath<VideoState, Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: Binding(get: { model.selected?.state[keyPath: path] ?? 0 }, set: { value in model.edit { $0.state[keyPath: path] = value } }), in: range, onEditingChanged: { active in if active { model.beginGesture() } else { model.endGesture() } }).accessibilityLabel(title)
        }
    }
    @ViewBuilder var video: some View {
        if let clip = model.selected {
            Text(model.selection.count == 1 ? clip.state.name : "\(model.selection.count) videos selected").font(.headline).lineLimit(2).help(clip.state.name)
            Text("Selected controls apply to all selected videos.").font(.caption).foregroundStyle(.secondary)
            Button(clip.state.paused || clip.state.speed == 0 ? "Play Selected" : "Pause Selected", systemImage: clip.state.paused || clip.state.speed == 0 ? "play.fill" : "pause.fill") {
                model.toggleSelectedPlayback()
            }.disabled(model.paused)
            if model.selection.count == 1 {
                // The shared frame clock refreshes the current playback position.
                let _ = model.now
                Text("\(max(0, clip.player.currentTime().seconds), specifier: "%.1f") / \(clip.duration, specifier: "%.1f") sec").font(.caption).monospacedDigit()
                Slider(value: Binding(get: { let t = clip.player.currentTime().seconds; return t.isFinite ? min(clip.duration, max(0, t)) : 0 }, set: { model.seek($0) }), in: 0...max(0.01, clip.duration), onEditingChanged: { active in if active { model.beginGesture() } else { model.endGesture() } }).accessibilityLabel("Playback position")
            }
            slider("Speed · \(Int(clip.state.speed * 100))%", \.speed, range: 0...16)
            slider("Volume · \(Int(clip.state.volume * 100))%", \.volume, range: 0...1)
            toggle("Mute", \.muted)
            toggle("Mirror", \.mirrored)
            Picker("Blend", selection: Binding(get: { clip.state.blend }, set: { value in model.edit { $0.state.blend = value } })) {
                ForEach(["normal", "screen", "multiply", "difference", "overlay"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            Divider()
            toggle("Keep Video", \.pinned).help("Retain the source during shuffle (K)")
            toggle("Lock Position", \.locked).help("Prevent dragging, resizing and grid movement (⇧K)")
            Button("Double Size") { model.edit { if !$0.state.locked { $0.state.width *= 2; $0.state.height *= 2; model.document.gridActive = false } } }
            HStack { Button("Forward") { model.layer(true) }; Button("Backward") { model.layer(false) } }
            HStack { Button("Duplicate") { model.duplicate() }; Button("Delete", role: .destructive) { model.removeSelection() } }
            Divider()
            Picker("Rating", selection: Binding(get: { clip.rating }, set: { model.rate($0) })) { Text("Unrated").tag(0); ForEach(1...10, id: \.self) { Text(String($0)).tag($0) } }.disabled(model.selection.count != 1)
            Button("Open in Default Player") { NSWorkspace.shared.open(clip.originalURL) }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.originalURL]) }
        } else { ContentUnavailableView("Select a video", systemImage: "cursorarrow", description: Text("Shift-click to select more. Drag a corner to resize the selection.")) }
    }
    var layers: some View {
        VStack(spacing: 8) {
            HStack { Button("Select All") { model.selectAll() }; Button("Clear", role: .destructive) { model.clear() } }
            ForEach(model.clips.reversed()) { clip in
                Button { model.select(clip, extending: NSEvent.modifierFlags.contains(.shift)); model.panel = "Layers" } label: {
                    HStack { Image(systemName: model.selectedIDs.contains(clip.id) ? "checkmark.circle.fill" : "circle"); Text(clip.state.name).lineLimit(1); Spacer(); if clip.state.pinned { Image(systemName: "pin.fill") }; if clip.state.locked { Image(systemName: "lock.fill") } }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.bordered).help(clip.state.name)
            }
        }
    }
    var scenes: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recall with 1–9. Capture with Shift-1–9.").font(.caption).foregroundStyle(.secondary)
            ForEach(0..<9, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("\(index + 1)").font(.headline)
                        if let scene = model.document.scenes[index] {
                            TextField("Scene name", text: Binding(get: { model.document.scenes[index]?.name ?? "" }, set: { model.renameScene(index, $0) })).textFieldStyle(.roundedBorder)
                            if let data = scene.thumbnail, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(width: 64, height: 40) }
                        } else { Text("Empty Scene").foregroundStyle(.secondary) }
                    }
                    HStack {
                        Button("Recall") { model.recallScene(index) }.disabled(model.document.scenes[index] == nil || model.busy)
                        Button(model.document.scenes[index] == nil ? "Capture" : "Update") { model.captureScene(index) }.disabled(!model.canEdit)
                        if model.document.activeScene == index { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                    }
                }
                Divider()
            }
        }
    }
    var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Source Folder").font(.headline)
            Text(model.document.folderPath.isEmpty ? "No folder selected" : model.document.folderPath).font(.caption).lineLimit(3).textSelection(.enabled)
            Button("Choose Folder…") { model.chooseFolder() }
            Stepper("Videos: \(model.document.count)", value: Binding(get: { model.document.count }, set: { value in model.changeCount(value) }), in: 1...100).disabled(model.busy)
            Button("Shuffle Videos") { model.shuffle() }.disabled(model.folder.isEmpty || model.busy)
            Toggle("Automatic Shuffle", isOn: Binding(get: { model.automatic }, set: { model.checkpoint(); model.automatic = $0; model.document.autoShuffle = $0; model.countdown = model.document.seconds; model.changed() })).disabled(model.folder.isEmpty)
            HStack { Text("Every"); TextField("Seconds", value: Binding(get: { model.document.seconds }, set: { model.document.seconds = min(3600, max(2, $0)); model.countdown = model.document.seconds; model.changed() }), format: .number).textFieldStyle(.roundedBorder); Text("sec") }
            if model.automatic { Text(model.paused ? "Timer paused" : "Next shuffle in \(Int(max(0, model.countdown))) sec").font(.caption) }
            Divider()
            Text("Canvas").font(.headline)
            Picker("Size", selection: Binding(get: { model.document.fixedCanvas ? "\(Int(model.document.canvasWidth))x\(Int(model.document.canvasHeight))" : "window" }, set: { value in
                let parts = value.split(separator: "x").compactMap { Double($0) }; model.setCanvas(parts.first ?? 0, parts.last ?? 0)
            })) {
                if model.document.fixedCanvas { Text("Current · \(Int(model.document.canvasWidth)) × \(Int(model.document.canvasHeight))").tag("\(Int(model.document.canvasWidth))x\(Int(model.document.canvasHeight))") }; Text("Window Size").tag("window"); Text("HD · 1280 × 720").tag("1280x720"); Text("Full HD · 1920 × 1080").tag("1920x1080"); Text("4K · 3840 × 2160").tag("3840x2160"); Text("Square · 1080 × 1080").tag("1080x1080"); Text("Portrait · 1080 × 1920").tag("1080x1920")
            }.disabled(model.recording != nil)
            Button("Rearrange Layout") { model.arrange() }
            Text("Keep Video protects a source. Lock Position also protects its geometry. Automatic shuffle waits during pause and file operations.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Button("Save Screenshot…") { model.screenshot() }
            Button(model.recording == nil ? "Record Output…" : "Stop Recording") { model.toggleRecording() }
        }
    }
}
