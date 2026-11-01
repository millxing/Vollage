import SwiftUI
import AppKit

struct NativeCanvas: View {
    @State var model = CanvasModel()
    let request: UUID?
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            ZStack {
                CanvasSurface(model: model)
                if model.clips.isEmpty && !model.performing {
                    ContentUnavailableView {
                        Label("Make a moving collage", systemImage: "rectangle.on.rectangle")
                    } description: { Text("Add videos or choose a folder. Your media stays on this Mac.") } actions: {
                        Button("Add Videos…") { model.chooseVideos() }
                        Button("Choose Folder…") { model.chooseFolder() }
                    }.preferredColorScheme(.dark)
                }
                VStack {
                    if model.busy {
                        HStack { ProgressView().controlSize(.small); Text(model.status); if model.status.hasPrefix("Preparing video") || model.status.hasPrefix("Preparing shuffle") { Button("Cancel") { model.cancelImport() } } }
                            .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(16)
                    }
                    Spacer()
                    if model.recording != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            HStack { Image(systemName: "record.circle.fill").foregroundStyle(.red); Text("Recording · \(Int(context.date.timeIntervalSince(model.recordingStarted)))s").monospacedDigit(); Button("Stop") { model.toggleRecording() } }
                                .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(16)
                        }
                    } else if !model.performing && !model.status.isEmpty {
                        Text(model.status).font(.caption).lineLimit(2).padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(8)
                    }
                }.allowsHitTesting(model.busy || model.recording != nil)
            }
            if !model.performing { InspectorView(model: model).frame(width: 304).disabled(model.busy) }
        }
        .navigationTitle(model.title)
        .focusedSceneValue(\.canvasModel, model)
        .background(WindowBinding(model: model))
        .background(EscapeHandler { guard model.performing else { return false }; model.performing = false; return true })
        .toolbar(model.performing ? .hidden : .visible, for: .windowToolbar)
        .toolbar {
            Button("Add Videos", systemImage: "plus") { model.chooseVideos() }.help("Add videos (⌘I)").disabled(!model.canEdit)
            Button(model.paused ? "Play All" : "Pause All", systemImage: model.paused ? "play.fill" : "pause.fill") { model.togglePlayback() }.help("Play or pause the composition (Space)")
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }.disabled(model.undoStack.isEmpty || !model.canEdit).help("Undo (⌘Z)")
            Button("Shuffle", systemImage: "shuffle") { model.shuffle() }.disabled(model.folder.isEmpty || model.busy).help("Shuffle unlocked videos (⇧G)")
            Spacer()
            Menu {
                Button("Save Project") { model.saveProject() }
                Button("Save Project As…") { model.saveProject(copy: true) }
                Button("Save Screenshot…") { model.screenshot() }
                Button(model.recording == nil ? "Record Output…" : "Stop Recording") { model.toggleRecording() }
            } label: { Label("Save and Output", systemImage: "square.and.arrow.up") }.help("Save projects, PNG screenshots, or MP4 recordings")
            Button("Clean View", systemImage: "play.rectangle") { model.performing.toggle() }.help("Hide controls (P); return with Escape")
            Button("Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right") { model.window?.toggleFullScreen(nil) }.help("Toggle fullscreen (Return)")
        }
        .alert("Vollage", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .task {
            AppHub.open = { value in openWindow(value: value) }
            if !AppHub.models.contains(where: { $0 === model }) { AppHub.models.append(model) }
            if let request, let url = AppHub.pending.removeValue(forKey: request) { await model.load(url) }
            if let request, let recovered = AppHub.recoveries.removeValue(forKey: request) {
                model.apply(recovered.state); model.projectURL = recovered.project; model.changed(); model.status = "Recovered unsaved changes"; await RecoveryStore.shared.remove(recovered.id)
            }
            await AppHub.restoreOnce()
            await NativeChecks.runIfRequested(model)
        }
    }
}
