import Foundation
import FrameShiftEffects

nonisolated struct VideoState: Codable, Equatable, Sendable, Identifiable {
    var id = UUID().uuidString
    var path: String
    var sourcePath: String
    var name: String
    var playbackPath: String
    var x = 0.4, y = 0.4, width = 0.2, height = 0.2
    var aspect = 16.0 / 9
    var speed: Float = 1
    var volume: Float = 1
    var muted = true, paused = false, mirrored = false, locked = false, pinned = false
    var blend = "normal"
    var time = 0.0
    var orientation: [Double]?
    // Optional storage gives older projects and recovery snapshots an empty stack.
    var effects: [EffectInstance]?
    static let maximumEffects = 16
    var effectStack: [EffectInstance] {
        get { effects ?? [] }
        set { effects = newValue.isEmpty ? nil : newValue }
    }
}
nonisolated struct SceneState: Codable, Equatable, Sendable {
    var name: String
    var videos: [VideoState]
    var paused: Bool
    var thumbnail: Data?
}
nonisolated struct DocumentState: Codable, Equatable, Sendable {
    var version = 2
    var videos: [VideoState] = []
    var scenes: [SceneState?] = Array(repeating: nil, count: 9)
    var paused = false
    var canvasWidth = 1920.0, canvasHeight = 1080.0
    var fixedCanvas = true
    var folderPath = ""
    var count = 4
    var seconds = 30.0
    var gridActive = false
    var autoShuffle: Bool?
    var activeScene = -1
}
nonisolated enum VollageError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
}
