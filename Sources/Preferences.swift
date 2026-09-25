import AppKit
import Combine
import SwiftUI

enum AccentChoice: String, CaseIterable, Identifiable {
    case green, blue, purple, pink, orange, white

    var id: String { rawValue }

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .green: return NSColor(red: 0.40, green: 0.80, blue: 0.42, alpha: 1)
        case .blue: return NSColor(red: 0.38, green: 0.66, blue: 1.00, alpha: 1)
        case .purple: return NSColor(red: 0.68, green: 0.52, blue: 1.00, alpha: 1)
        case .pink: return NSColor(red: 1.00, green: 0.45, blue: 0.66, alpha: 1)
        case .orange: return NSColor(red: 1.00, green: 0.63, blue: 0.30, alpha: 1)
        case .white: return NSColor(white: 0.92, alpha: 1)
        }
    }
}

/// Look-and-feel settings changed from the panel's settings sheet.
final class Preferences: ObservableObject {
    @Published var accent: AccentChoice { didSet { defaults.set(accent.rawValue, forKey: "accent") } }
    @Published var use24Hour: Bool { didSet { defaults.set(use24Hour, forKey: "use24Hour") } }
    @Published var artworkTint: Bool { didSet { defaults.set(artworkTint, forKey: "artworkTint") } }
    @Published var showDate: Bool { didSet { defaults.set(showDate, forKey: "showDate") } }

    private let defaults = UserDefaults.standard

    init() {
        accent = AccentChoice(rawValue: defaults.string(forKey: "accent") ?? "") ?? .green
        use24Hour = defaults.object(forKey: "use24Hour") as? Bool ?? true
        artworkTint = defaults.object(forKey: "artworkTint") as? Bool ?? true
        showDate = defaults.object(forKey: "showDate") as? Bool ?? true
    }
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue: Color = AccentChoice.green.color
}

extension EnvironmentValues {
    var deckAccent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}
