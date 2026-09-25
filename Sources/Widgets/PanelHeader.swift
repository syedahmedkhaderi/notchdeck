import SwiftUI

/// Top strip. It sits beside the camera housing, so the centre is left empty.
struct PanelHeader: View {
    @ObservedObject var prefs: Preferences
    var arranging: Bool
    var notchWidth: CGFloat
    var height: CGFloat
    var onRefresh: () -> Void
    var onArrange: () -> Void
    var onQuit: () -> Void

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        return f
    }()
    private static let time24: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let time12: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            TimelineView(.everyMinute) { context in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text((prefs.use24Hour ? Self.time24 : Self.time12).string(from: context.date))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .monospacedDigit()
                    if prefs.showDate {
                        Text(Self.dateFormatter.string(from: context.date))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: notchWidth + 16)

            HStack(spacing: 4) {
                iconButton("arrow.clockwise", help: "Refresh", action: onRefresh)
                iconButton(arranging ? "checkmark" : "slider.horizontal.3",
                           help: arranging ? "Done" : "Customize",
                           action: onArrange,
                           highlighted: arranging)
                iconButton("power", help: "Quit NotchDeck", action: onQuit)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(height: height)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void,
                            highlighted: Bool = false) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(highlighted ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 22, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(highlighted ? Theme.fillStrong : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
        .help(help)
    }
}

/// Plain button that lifts slightly on hover and dims on press.
struct HoverButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration)
    }

    private struct HoverBody: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.08 : 0))
                )
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
        }
    }
}
