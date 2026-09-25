import SwiftUI

enum Theme {
    // MARK: Colors
    static let panelBackground = Color.black
    static let divider = Color.white.opacity(0.08)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)
    static let fill = Color.white.opacity(0.07)
    static let fillStrong = Color.white.opacity(0.12)
    static let trackBackground = Color.white.opacity(0.12)
    static let warning = Color(red: 1.0, green: 0.42, blue: 0.38)

    // MARK: Metrics
    static let contentHeight: CGFloat = 138
    static let minHeaderHeight: CGFloat = 32
    static let panelCornerRadius: CGFloat = 26
    static let collapsedCornerRadius: CGFloat = 10
    /// Outward flare where the open panel meets the menu bar.
    static let earRadius: CGFloat = 12
    static let windowMargin: CGFloat = 24
    static let settingsWidth: CGFloat = 780
    static let gutter: CGFloat = 16

    static func width(for id: WidgetID) -> CGFloat {
        switch id {
        case .player: return 290
        case .calendar: return 176
        case .memory: return 180
        case .battery: return 140
        case .brightness: return 76
        case .mirror: return 196
        }
    }

    static func contentWidth(of widgets: [WidgetID]) -> CGFloat {
        widgets.reduce(0) { $0 + width(for: $1) } + CGFloat(max(widgets.count - 1, 0))
    }
}

/// Small caps-style label every widget uses for its heading.
struct WidgetHeading: View {
    var title: String
    var symbol: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(Theme.textTertiary)
        .lineLimit(1)
    }
}
