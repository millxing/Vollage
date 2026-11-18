// Adapted from FrameShift's effect definitions.
import Foundation

/// One adjustable setting of an effect. Values are Doubles; a setting with
/// `options` is a picker whose value is the option's index.
public struct ParamSpec: Sendable, Hashable {
    public enum Unit: Sendable, Hashable { case number, percent, frames, degrees }

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
    public var isInteger: Bool { options != nil || unit == .frames }

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
        case .number:
            return abs(value) < 10 ? String(format: "%.3g", value) : String(format: "%.0f", value)
        }
    }

    /// Every effect ends with Mix: how much of the effect shows over its input.
    public static let mix = ParamSpec("mix", "Mix", 0...1, 1, unit: .percent)
}

public enum EffectKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case displacementMap, slitScan, videoFeedback

    public var id: Self { self }

    public var title: String {
        switch self {
        case .displacementMap: "Displacement Map"
        case .slitScan: "Slit-Scan"
        case .videoFeedback: "Video Feedback"
        }
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
