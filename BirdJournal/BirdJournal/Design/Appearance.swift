import SwiftUI

/// The appearance the reader picks in Settings: follow the system, or keep the journal light or dark. Stored in
/// user defaults under `key` and applied once at the root, so every tab, sheet and the navigation bars follow it.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    static let key = "appearance"

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// The scheme to force, or nil to follow the system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}
