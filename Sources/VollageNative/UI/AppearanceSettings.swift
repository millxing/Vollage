import AppKit
import Observation
import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var native: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@Observable
final class AppearanceStore {
    static let shared = AppearanceStore(defaults: ProcessInfo.processInfo.environment["VOLLAGE_TEST_MEDIA"] == nil
        ? .standard : UserDefaults(suiteName: "com.vollage.native.appearance-tests")!)
    private let defaults: UserDefaults
    var mode: AppAppearance {
        didSet {
            defaults.set(mode.rawValue, forKey: "appearance.mode")
            apply()
        }
    }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        mode = AppAppearance(rawValue: defaults.string(forKey: "appearance.mode") ?? "") ?? .system
    }
    // AppKit applies this to existing and future windows, title bars, and menus.
    // nil removes the override so future system appearance changes are followed.
    func apply() { NSApp.appearance = mode.native }
}

struct AppearanceSettings: View {
    @Bindable private var store = AppearanceStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $store.mode) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("System follows your Mac’s appearance. Changes apply to all Vollage windows.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fitsContent()
        .navigationTitle("Vollage Settings")
        .noInitialFocus()
    }
}
