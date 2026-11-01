import SwiftUI
import AVKit
import UniformTypeIdentifiers

@Observable final class Clip: Identifiable {
    let id = UUID()
    let url: URL
    let player: AVQueuePlayer
    let looper: AVPlayerLooper
    var x = 0.5
    var y = 0.5
    var width = 0.3
    var muted = true { didSet { player.isMuted = muted } }
    var speed: Float = 1 { didSet { player.rate = speed } }
    var mirrored = false
    var locked = false
    init(_ url: URL) {
        self.url = url
        player = AVQueuePlayer()
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        player.isMuted = true
        player.play()
    }
}
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
struct ClipRecord: Codable {
    var path: String
    var x: Double
    var y: Double
    var width: Double
    var muted: Bool
    var speed: Float
    var mirrored: Bool
    var locked: Bool
}
struct NativeCanvas: View {
    @State private var model = CanvasModel()
    @State private var dragOrigin: CGPoint?
    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black.onTapGesture { model.selection = nil }
                    if model.clips.isEmpty {
                        ContentUnavailableView("Make a moving collage", systemImage: "rectangle.on.rectangle", description: Text("Add videos or choose a folder to begin. Your media stays on this Mac."))
                            .foregroundStyle(.white)
                    }
                    ForEach(model.clips) { clip in
                        PlayerSurface(player: clip.player)
                            .scaleEffect(x: clip.mirrored ? -1 : 1, y: 1)
                            .allowsHitTesting(false)
                            .frame(width: geo.size.width * clip.width, height: geo.size.height * clip.width)
                            .overlay { if !model.performing { Rectangle().fill(.clear).contentShape(Rectangle()).onTapGesture { model.selection = clip.id } } }
                            .overlay { if model.selection == clip.id && !model.performing { Rectangle().stroke(clip.locked ? Color.orange : Color.accentColor, lineWidth: 2).allowsHitTesting(false) } }
                            .position(x: geo.size.width * clip.x, y: geo.size.height * clip.y) // grid: ok freeform video canvas
                            .gesture(DragGesture(coordinateSpace: .named("canvas")).onChanged { value in
                                guard !model.performing, !clip.locked else { return }
                                model.selection = clip.id
                                if dragOrigin == nil { dragOrigin = CGPoint(x: clip.x, y: clip.y) }
                                clip.x = min(1, max(0, dragOrigin!.x + value.translation.width / geo.size.width))
                                clip.y = min(1, max(0, dragOrigin!.y + value.translation.height / geo.size.height))
                            }.onEnded { _ in dragOrigin = nil })
                    }
                }
                .coordinateSpace(name: "canvas")
                .clipped()
                .dropDestination(for: URL.self) { urls, _ in guard !model.performing else { return false }; model.add(urls); return true }
            }
            if !model.performing {
                VStack(alignment: .leading, spacing: 16) {
                    Text("VOLLAGE").font(.headline).tracking(3)
                    Text("\(model.clips.count) videos").foregroundStyle(.secondary)
                    Divider()
                    if let selected = model.selected { inspector(selected) }
                    else { Text("Select a video to adjust playback and placement.").foregroundStyle(.secondary) }
                    Spacer()
                    Stepper("Videos: \(model.count)", value: $model.count, in: 1...100)
                    Button("Choose folder…", systemImage: "folder") { model.chooseFolder() }
                    Button("Shuffle videos", systemImage: "shuffle") { model.shuffle() }.disabled(model.folder.isEmpty)
                }.padding(20).frame(width: 240)
            }
        }
        .focusedSceneValue(\.canvasModel, model)
        .background(EscapeHandler {
            guard model.performing else { return false }
            model.performing = false
            return true
        })
        .toolbar(model.performing ? .hidden : .visible, for: .windowToolbar)
        .task { await NativeChecks.runIfRequested(model) }
        .onDisappear { model.clips.forEach { $0.player.pause() } }
        .toolbar {
            Button("Add videos", systemImage: "plus") { model.chooseVideos() }
            Button(model.paused ? "Play all" : "Pause all", systemImage: model.paused ? "play.fill" : "pause.fill") {
                model.togglePlayback()
            }
            Button("Arrange grid", systemImage: "square.grid.2x2") { model.arrange() }
            Spacer()
            Button("Open", systemImage: "folder") { model.openProject() }
            Button("Save", systemImage: "square.and.arrow.down") { model.saveProject() }
            Button(model.performing ? "Edit" : "Perform", systemImage: "play.rectangle") { model.performing.toggle() }
        }
        .alert("Vollage", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
    func inspector(_ clip: Clip) -> some View {
        @Bindable var clip = clip
        return VStack(alignment: .leading, spacing: 16) {
            Text(clip.url.lastPathComponent).font(.headline).lineLimit(2)
            Toggle("Mute", isOn: $clip.muted)
            Toggle("Mirror", isOn: $clip.mirrored)
            Toggle("Lock position", isOn: $clip.locked)
            Text("Speed · \(Int(clip.speed * 100))%")
            Slider(value: $clip.speed, in: 0...4).disabled(model.paused)
            Text("Size")
            Slider(value: $clip.width, in: 0.05...1).disabled(clip.locked)
            Button("Bring to front") { model.clips.removeAll { $0.id == clip.id }; model.clips.append(clip) }
            Button("Remove video", role: .destructive) { model.remove(clip) }
        }
    }

}
