import SwiftUI
import AppKit

struct InspectorView: View {
    @Bindable var model: CanvasModel
    @State private var sourceExpanded = false
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Vollage").font(.headline)
                Spacer()
                Text("\(model.clips.count) \(model.clips.count == 1 ? "video" : "videos")").foregroundStyle(.secondary)
            }
            Picker("Inspector panel", selection: $model.panel) {
                ForEach(["Video", "Layers", "Scenes", "Setup"], id: \.self) { Text($0).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch model.panel {
                    case "Video": video
                    case "Layers": layers
                    case "Scenes": scenes
                    default: setup
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4).padding(.trailing, 4)
            }
        }.padding(16).background(.background)
    }
    func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).accessibilityAddTraits(.isHeader).accessibilityElement(children: .ignore).accessibilityLabel(title).accessibilityAddTraits(.isStaticText)
            content()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func toggle(_ title: String, _ path: WritableKeyPath<VideoState, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { model.selected?.state[keyPath: path] ?? false }, set: { value in model.edit { $0.state[keyPath: path] = value } })).help(title)
    }
    func slider(_ title: String, _ path: WritableKeyPath<VideoState, Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
            Slider(value: Binding(get: { model.selected?.state[keyPath: path] ?? 0 }, set: { value in model.edit { $0.state[keyPath: path] = value } }), in: range, onEditingChanged: { active in if active { model.beginGesture() } else { model.endGesture() } }).accessibilityLabel(title).help(title)
        }
    }
    @ViewBuilder var video: some View {
        if let clip = model.selected {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.selection.count == 1 ? clip.state.name : "\(model.selection.count) videos selected").font(.headline).lineLimit(2).help(clip.state.name).accessibilityElement(children: .ignore).accessibilityLabel(model.selection.count == 1 ? clip.state.name : "\(model.selection.count) videos selected").accessibilityAddTraits(.isStaticText)
                if model.selection.count > 1 {
                    Text("Playback, appearance and placement affect the selection.")
                }
            }
            section("Playback") {
                Button(clip.state.paused || clip.state.speed == 0 ? "Play Selected" : "Pause Selected", systemImage: clip.state.paused || clip.state.speed == 0 ? "play.fill" : "pause.fill") {
                    model.toggleSelectedPlayback()
                }.disabled(model.paused).help(model.paused ? "Resume Play All to use individual playback" : "Play or pause selected videos")
                if model.selection.count == 1 {
                    // Refresh the time label and the slider together; AVPlayer time is not observable.
                    TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                        VStack(spacing: 4) {
                            HStack {
                                Text("\(playbackTime(clip), specifier: "%.1f") s")
                                Spacer()
                                Text("\(clip.duration, specifier: "%.1f") s")
                            }.monospacedDigit()
                            Slider(value: Binding(get: { playbackTime(clip) }, set: { model.seek($0) }), in: 0...max(0.01, clip.duration), onEditingChanged: { active in if active { model.beginGesture() } else { model.endGesture() } })
                                .accessibilityLabel("Playback position").accessibilityValue("\(playbackTime(clip), specifier: "%.1f") of \(clip.duration, specifier: "%.1f") seconds").help("Seek within the selected video")
                        }
                    }
                }
                slider("Speed · \(Int(clip.state.speed * 100))%", \.speed, range: 0...16)
                slider("Volume · \(Int(clip.state.volume * 100))%", \.volume, range: 0...1)
                toggle("Mute", \.muted)
            }
            Divider()
            section("Appearance") {
                toggle("Mirror", \.mirrored)
                Picker("Blend", selection: Binding(get: { clip.state.blend }, set: { value in model.edit { $0.state.blend = value } })) {
                    ForEach(["normal", "screen", "multiply", "difference", "overlay"], id: \.self) { Text($0.capitalized).tag($0) }
                }
            }
            Divider()
            section("Placement") {
                toggle("Keep Video", \.pinned).help("Keep this source when shuffling (K)")
                toggle("Lock Position", \.locked).help("Keep the source and prevent movement or resizing (⇧K)")
                HStack {
                    Button("Bring Forward") { model.layer(true) }
                    Button("Send Backward") { model.layer(false) }
                }
                HStack {
                    Button("Double Size") { model.edit { if !$0.state.locked { $0.state.width *= 2; $0.state.height *= 2; model.document.gridActive = false } } }.disabled(model.selection.allSatisfy { $0.state.locked })
                    Button("Duplicate") { model.duplicate() }.help("Duplicate selected videos (⌘D or Option-drag)")
                    Button("Delete", role: .destructive) { model.removeSelection() }.help("Delete selected videos (Delete); undo with ⌘Z")
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                DisclosureGroup("Source", isExpanded: $sourceExpanded) { EmptyView() }
                if sourceExpanded {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Rating", selection: Binding(get: { clip.rating }, set: { model.rate($0) })) {
                            Text("Unrated").tag(0)
                            ForEach(1...10, id: \.self) { Text(String($0)).tag($0) }
                        }.disabled(model.selection.count != 1)
                        Button("Open in Default Player") { NSWorkspace.shared.open(clip.originalURL) }
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip.originalURL]) }
                        if model.selection.count > 1 { Text("Source actions use the primary video. Rating requires one video.") }
                    }
                }
            }
        } else if model.clips.isEmpty {
            ContentUnavailableView {
                Label("No videos", systemImage: "film")
            } description: {
                Text("Add videos to start your composition.")
            } actions: {
                Button("Add Videos…") { model.chooseVideos() }
            }
        } else {
            ContentUnavailableView("Select a video", systemImage: "cursorarrow", description: Text("Click the canvas or choose a video in Layers. Shift-click to select more."))
        }
    }
    func playbackTime(_ clip: Clip) -> Double {
        let time = clip.player.currentTime().seconds
        return time.isFinite ? min(clip.duration, max(0, time)) : 0
    }
    var layers: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Front to back")
                Spacer()
                Button("Select All") { model.selectAll() }.disabled(model.clips.isEmpty)
            }
            if model.clips.isEmpty {
                ContentUnavailableView("No videos", systemImage: "square.3.layers.3d", description: Text("Add videos to start building your composition."))
            }
            ForEach(model.clips.reversed()) { clip in
                let selected = model.selectedIDs.contains(clip.id)
                Button { model.select(clip, extending: (NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags).contains(.shift)); model.panel = "Layers" } label: {
                    HStack(spacing: 8) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle").foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Text(clip.state.name).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        if clip.state.pinned { Image(systemName: "pin.fill").accessibilityLabel("Kept during shuffle") }
                        if clip.state.locked { Image(systemName: "lock.fill").accessibilityLabel("Position locked") }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .background(selected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel(clip.state.name).accessibilityValue(selected ? "Selected" : "Not selected").help(clip.state.name)
            }
            if !model.clips.isEmpty {
                Divider()
                Button("Remove All Videos", role: .destructive) { model.clear() }.help("Remove all videos from the canvas; undo with ⌘Z")
                Text("Remove affects the canvas. Saved scenes are kept. Undo with ⌘Z.")
            }
        }
    }
    var scenes: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recall: 1–9 · Capture: ⇧1–9")
            ForEach(0..<9, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text("\(index + 1)").font(.headline).frame(width: 16)
                        if let scene = model.document.scenes[index] {
                            TextField("Scene name", text: Binding(get: { model.document.scenes[index]?.name ?? "" }, set: { model.renameScene(index, $0) }))
                                .textFieldStyle(.roundedBorder).accessibilityLabel("Scene \(index + 1) name")
                            if let data = scene.thumbnail, let image = NSImage(data: data) { Image(nsImage: image).resizable().scaledToFit().frame(width: 48, height: 32).accessibilityHidden(true) }
                        } else {
                            Text("Empty").foregroundStyle(.secondary)
                            Spacer()
                            Button("Capture") { model.captureScene(index) }.disabled(!model.canEdit || model.clips.isEmpty).accessibilityLabel("Capture scene \(index + 1)")
                        }
                    }
                    if model.document.scenes[index] != nil {
                        HStack {
                            Button("Recall") { model.recallScene(index) }.disabled(model.busy).accessibilityLabel("Recall scene \(index + 1)")
                            Button("Update") { model.captureScene(index) }.disabled(!model.canEdit).accessibilityLabel("Update scene \(index + 1)")
                            Spacer()
                            if model.document.activeScene == index { Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary) }
                        }
                    }
                }.padding(.vertical, 4)
                if index < 8 { Divider() }
            }
        }
    }
    var setup: some View {
        VStack(alignment: .leading, spacing: 16) {
            section("Source Folder") {
                Text(model.document.folderPath.isEmpty ? "No folder selected" : model.document.folderPath).lineLimit(3).truncationMode(.middle).textSelection(.enabled).help(model.document.folderPath)
                Button("Choose Folder…") { model.chooseFolder() }
            }
            Divider()
            section("Shuffle") {
                Stepper("Requested videos: \(model.document.count)", value: Binding(get: { model.document.count }, set: { model.changeCount($0) }), in: 1...100).disabled(model.busy)
                Button("Shuffle Videos") { model.shuffle() }.disabled(model.folder.isEmpty || model.busy)
                Toggle("Automatic Shuffle", isOn: Binding(get: { model.automatic }, set: { model.checkpoint(); model.automatic = $0; model.document.autoShuffle = $0; model.countdown = model.document.seconds; model.changed() })).disabled(model.folder.isEmpty)
                HStack {
                    Text("Every")
                    TextField("Seconds", value: Binding(get: { model.document.seconds }, set: { model.document.seconds = min(3600, max(2, $0)); model.countdown = model.document.seconds; model.changed() }), format: .number).textFieldStyle(.roundedBorder).accessibilityLabel("Shuffle interval in seconds")
                    Text("sec")
                }
                if model.automatic { Text(model.paused ? "Timer paused" : "Next shuffle in \(Int(max(0, model.countdown))) sec").foregroundStyle(.secondary) }
                Text("Keep Video retains a source. Lock Position also keeps its geometry.")
            }
            Divider()
            section("Canvas") {
                Picker("Size", selection: Binding(get: { model.document.fixedCanvas ? "\(Int(model.document.canvasWidth))x\(Int(model.document.canvasHeight))" : "window" }, set: { value in
                    let parts = value.split(separator: "x").compactMap { Double($0) }; model.setCanvas(parts.first ?? 0, parts.last ?? 0)
                })) {
                    if model.document.fixedCanvas { Text("Current · \(Int(model.document.canvasWidth)) × \(Int(model.document.canvasHeight))").tag("\(Int(model.document.canvasWidth))x\(Int(model.document.canvasHeight))") }
                    Text("Window Size").tag("window"); Text("HD · 1280 × 720").tag("1280x720"); Text("Full HD · 1920 × 1080").tag("1920x1080"); Text("4K · 3840 × 2160").tag("3840x2160"); Text("Square · 1080 × 1080").tag("1080x1080"); Text("Portrait · 1080 × 1920").tag("1080x1920")
                }.disabled(model.recording != nil)
                Button(model.resizingOutput ? "Done Resizing" : "Resize Output Frame") { model.toggleOutputResize() }.disabled(model.recording != nil)
                Text(model.resizingOutput ? "Drag the white edges or corners. Escape finishes resizing." : "The canvas frame is the area saved to PNG and MP4.").foregroundStyle(.secondary)
                Text("Output: \(Int(model.document.canvasWidth)) × \(Int(model.document.canvasHeight)) pixels").monospacedDigit()
                Button("Arrange Grid") { model.arrange() }
            }
            Divider()
            section("Output") {
                Button("Save Screenshot…") { model.screenshot() }
                Button(model.recording == nil ? "Record Output…" : "Stop Recording") { model.toggleRecording() }
            }
        }
    }
}
