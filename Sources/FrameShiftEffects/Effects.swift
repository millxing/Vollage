// Adapted from FrameShift's effect definitions.
import Foundation

/// One adjustable setting of an effect. Values are Doubles; a setting with
/// `options` is a picker whose value is the option's index.
public struct ParamSpec: Sendable, Hashable {
    public enum Unit: Sendable, Hashable { case number, count, percent, frames, degrees, pixels }

    public let key: String
    public let label: String
    public let range: ClosedRange<Double>
    public let defaultValue: Double
    public let options: [String]?
    public let unit: Unit

    public init(_ key: String, _ label: String, _ range: ClosedRange<Double>, _ defaultValue: Double,
                unit: Unit = .number) {
        self.key = key
        self.label = label
        self.range = range
        self.defaultValue = defaultValue
        self.options = nil
        self.unit = unit
    }

    public init(_ key: String, _ label: String, options: [String], _ defaultIndex: Int = 0) {
        self.key = key
        self.label = label
        self.range = 0...Double(options.count - 1)
        self.defaultValue = Double(defaultIndex)
        self.options = options
        self.unit = .number
    }

    /// Settings counted in whole steps (frames, pixels, picker options).
    public var isInteger: Bool { options != nil || unit == .count || unit == .frames || unit == .pixels }

    /// Clamps to the range and rounds whole-step settings.
    public func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return isInteger ? clamped.rounded() : clamped
    }

    /// The value as people read it next to the slider.
    public func format(_ value: Double) -> String {
        if let options { return options[Int(clamp(value))] }
        switch unit {
        case .percent: return "\(Int((value * 100).rounded()))%"
        case .frames: return Int(value) == 1 ? "1 frame" : "\(Int(value)) frames"
        case .degrees: return String(format: "%.1f°", value)
        case .pixels: return "\(Int(value)) px"
        case .count: return "\(Int(value))"
        case .number:
            return abs(value) < 10 ? String(format: "%.3g", value) : String(format: "%.0f", value)
        }
    }

    /// Every effect ends with Mix: how much of the effect shows over its input.
    public static let mix = ParamSpec("mix", "Mix", 0...1, 1, unit: .percent)
}

/// The groups the Add Effect menu shows.
public enum EffectCategory: String, CaseIterable, Sendable {
    case temporal, feedback, spatial, motion

    public var title: String {
        switch self {
        case .temporal: "Temporal"
        case .feedback: "Feedback"
        case .spatial: "Spatial"
        case .motion: "Motion"
        }
    }
}

/// The order of `params` is the order the Metal kernel reads them in (p[0], p[1], ...).
/// Never reorder existing keys. New cases go at the end, because projects store the name.
public enum EffectKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case displacementMap, slitScan, videoFeedback
    case timeDisplacement, motionEcho, timeStacking, rollingShutter
    case motionTrails, temporalKaleidoscope, scanlineDistortion, pixelSort, frameDifference

    public var id: Self { self }

    public var title: String {
        switch self {
        case .displacementMap: "Displacement Map"
        case .slitScan: "Slit-Scan"
        case .videoFeedback: "Video Feedback"
        case .timeDisplacement: "Time Displacement"
        case .motionEcho: "Motion Echo"
        case .timeStacking: "Time Stacking"
        case .rollingShutter: "Rolling Shutter"
        case .motionTrails: "Motion Trails"
        case .temporalKaleidoscope: "Temporal Kaleidoscope"
        case .scanlineDistortion: "Scanline Distortion"
        case .pixelSort: "Pixel Sort"
        case .frameDifference: "Frame Difference"
        }
    }

    public var summary: String {
        switch self {
        case .displacementMap: "Pushes pixels around with noise, waves, or brightness."
        case .slitScan: "Builds each frame from slices taken at different moments."
        case .videoFeedback: "Feeds the previous output back in, zoomed and turned."
        case .timeDisplacement: "Shows each region of the frame from a different point in time."
        case .motionEcho: "Shows several past positions of moving subjects at once."
        case .timeStacking: "Combines recent frames by average, brightest, or darkest."
        case .rollingShutter: "Captures each row a little later than the one above."
        case .motionTrails: "Leaves fading trails behind moving subjects."
        case .temporalKaleidoscope: "Mirrors the frame into slices, each from a different moment."
        case .scanlineDistortion: "Offsets individual rows or columns."
        case .pixelSort: "Sorts runs of pixels by brightness, hue, or saturation."
        case .frameDifference: "Shows only what changed since the last frame."
        }
    }

    public var category: EffectCategory {
        switch self {
        case .slitScan, .timeDisplacement, .motionEcho, .timeStacking, .rollingShutter: .temporal
        case .videoFeedback, .motionTrails, .temporalKaleidoscope: .feedback
        case .displacementMap, .scanlineDistortion, .pixelSort: .spatial
        case .frameDifference: .motion
        }
    }

    public static func kinds(in category: EffectCategory) -> [EffectKind] {
        allCases.filter { $0.category == category }
    }

    /// Frames of input history the effect reads (0 for none).
    public var historyDepth: Int {
        switch self {
        case .slitScan, .timeDisplacement, .temporalKaleidoscope: 64
        case .timeStacking: 48
        case .motionEcho, .rollingShutter: 33
        case .frameDifference: 2
        case .motionTrails, .videoFeedback, .displacementMap, .scanlineDistortion, .pixelSort: 0
        }
    }

    /// True when the effect keeps its own result from frame to frame, or hands a mask on.
    public var usesAccumulator: Bool {
        self == .videoFeedback || self == .motionTrails || self == .frameDifference
    }

    public var params: [ParamSpec] {
        // The Metal kernels use this parameter order.
        let settings: [ParamSpec] = switch self {
        case .displacementMap: [
            ParamSpec("source", "Source", options: ["Noise", "Sine Waves", "Ripples", "Brightness"]),
            ParamSpec("amount", "Amount", 0...0.2, 0.03, unit: .percent),
            ParamSpec("scale", "Scale", 0.5...20, 4),
            ParamSpec("speed", "Speed", 0...3, 0.5),
            ParamSpec("axis", "Axis", options: ["Both", "Horizontal", "Vertical"]),
        ]

        case .slitScan: [
            ParamSpec("direction", "Direction", options: ["Top to Bottom", "Bottom to Top", "Left to Right", "Right to Left"]),
            ParamSpec("span", "Time span", 2...64, 64, unit: .frames),
            ParamSpec("skip", "Sample every", 1...8, 2, unit: .frames),
        ]

        case .videoFeedback: [
            ParamSpec("amount", "Feedback", 0...1, 0.85, unit: .percent),
            ParamSpec("zoom", "Zoom", 0.9...1.1, 1.02),
            ParamSpec("rotation", "Rotation", -10...10, 1.5, unit: .degrees),
            ParamSpec("hue", "Hue shift", 0...0.2, 0.02),
            ParamSpec("blend", "Blend", options: ["Mix", "Add", "Lighten", "Difference"]),
        ]

        case .timeDisplacement: [
            ParamSpec("map", "Map", options: ["Noise", "Vertical Gradient", "Horizontal Gradient", "Radial", "Brightness"]),
            ParamSpec("depth", "Depth", 2...64, 24, unit: .frames),
            ParamSpec("scale", "Noise scale", 0.5...10, 2),
            ParamSpec("speed", "Speed", 0...2, 0.3),
        ]
        case .motionEcho: [
            ParamSpec("echoes", "Echoes", 2...8, 4, unit: .count),
            ParamSpec("spacing", "Spacing", 1...8, 3, unit: .frames),
            ParamSpec("decay", "Decay", 0...1, 0.6, unit: .percent),
            ParamSpec("blend", "Blend", options: ["Average", "Lighten", "Darken"]),
        ]
        case .timeStacking: [
            ParamSpec("mode", "Mode", options: ["Mean", "Brightest", "Darkest"]),
            ParamSpec("window", "Window", 2...48, 16, unit: .frames),
        ]
        case .rollingShutter: [
            ParamSpec("direction", "Direction", options: ["Top to Bottom", "Left to Right"]),
            ParamSpec("skew", "Skew", 0...32, 8, unit: .frames),
            ParamSpec("wobble", "Wobble", 0...1, 0, unit: .percent),
        ]
        case .motionTrails: [
            ParamSpec("threshold", "Threshold", 0...0.5, 0.08),
            ParamSpec("length", "Trail length", 0...0.99, 0.92, unit: .percent),
        ]
        case .temporalKaleidoscope: [
            ParamSpec("segments", "Segments", 2...16, 6, unit: .count),
            ParamSpec("delay", "Delay per segment", 0...12, 3, unit: .frames),
            ParamSpec("rotation", "Rotation", 0...360, 0, unit: .degrees),
            ParamSpec("spin", "Spin", 0...1, 0),
        ]
        case .scanlineDistortion: [
            ParamSpec("orientation", "Lines", options: ["Rows", "Columns"]),
            ParamSpec("pattern", "Pattern", options: ["Sine", "Noise", "Jitter"]),
            ParamSpec("amount", "Amount", 0...0.3, 0.05, unit: .percent),
            ParamSpec("frequency", "Frequency", 1...100, 12),
            ParamSpec("band", "Band size", 1...64, 2, unit: .pixels),
            ParamSpec("speed", "Speed", 0...5, 1),
        ]
        case .pixelSort: [
            ParamSpec("direction", "Direction", options: ["Horizontal", "Vertical"]),
            ParamSpec("key", "Sort by", options: ["Brightness", "Hue", "Saturation"]),
            ParamSpec("lower", "Lower threshold", 0...1, 0.25, unit: .percent),
            ParamSpec("upper", "Upper threshold", 0...1, 0.8, unit: .percent),
            ParamSpec("order", "Order", options: ["Ascending", "Descending"]),
        ]
        case .frameDifference: [
            ParamSpec("output", "Output", options: ["Difference", "Isolate Motion", "Mask Next Effect"]),
            ParamSpec("gain", "Gain", 1...20, 4),
            ParamSpec("threshold", "Threshold", 0...0.5, 0.05),
        ]
        }
        return settings + [.mix]
    }

    public func spec(_ key: String) -> ParamSpec? { params.first { $0.key == key } }
}

/// One effect in a stack, with its own settings.
public struct EffectInstance: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: EffectKind
    public var isEnabled: Bool
    public var values: [String: Double]

    public init(kind: EffectKind, id: UUID = UUID()) {
        self.id = id
        self.kind = kind
        self.isEnabled = true
        self.values = Dictionary(uniqueKeysWithValues: kind.params.map { ($0.key, $0.defaultValue) })
    }

    /// The setting's value, clamped, or its default when missing.
    public func value(_ key: String) -> Double {
        guard let spec = kind.spec(key) else { return 0 }
        return spec.clamp(values[key] ?? spec.defaultValue)
    }

    /// Sets a value, clamped to the setting's range. Unknown keys are ignored.
    public mutating func set(_ key: String, _ value: Double) {
        guard let spec = kind.spec(key) else { return }
        values[key] = spec.clamp(value)
    }

    public var kernelValues: [Float] { kind.params.map { Float(value($0.key)) } }
}
