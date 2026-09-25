import SwiftUI

/// In-panel customization: which widgets show, their order, and appearance.
/// Everything is a plain control inside the panel; system pickers would steal
/// focus from the non-activating window and close it.
struct SettingsView: View {
    @ObservedObject var order: WidgetOrder
    @ObservedObject var prefs: Preferences
    var onDone: () -> Void
    @Environment(\.deckAccent) private var accent

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            widgetsSection
                .padding(.leading, 20)
                .padding(.trailing, 18)
            Rectangle().fill(Theme.divider).frame(width: 1).padding(.vertical, 4)
            appearanceSection
                .frame(width: 240, alignment: .leading)
                .padding(.horizontal, 18)
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Widgets

    private var widgetsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                sectionLabel("Widgets")
                Text("tap to show or hide")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Button(action: order.reset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .buttonStyle(HoverButtonStyle())
            }
            HStack(spacing: 6) {
                ForEach(order.order) { tile($0) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func tile(_ id: WidgetID) -> some View {
        let index = order.order.firstIndex(of: id) ?? 0
        let on = order.isVisible(id)
        return VStack(spacing: 5) {
            Button { order.toggle(id) } label: {
                VStack(spacing: 6) {
                    Image(systemName: id.symbol)
                        .font(.system(size: 14, weight: .medium))
                        .frame(height: 18)
                    Text(id.title)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(on ? Theme.textPrimary : Theme.textTertiary)
                .frame(width: 74, height: 58)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(on ? Theme.fillStrong : Theme.fill.opacity(0.5))
                )
                .overlay(alignment: .topTrailing) {
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(on ? accent : Theme.textTertiary)
                        .padding(6)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())

            HStack(spacing: 4) {
                arrow("chevron.left", enabled: index > 0) { order.move(id, by: -1) }
                arrow("chevron.right", enabled: index < order.order.count - 1) { order.move(id, by: 1) }
            }
        }
    }

    private func arrow(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 30, height: 18)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.fill))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.3)
    }

    // MARK: Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionLabel("Accent")
            HStack(spacing: 8) {
                ForEach(AccentChoice.allCases) { choice in
                    Button { prefs.accent = choice } label: {
                        Circle()
                            .fill(choice.color)
                            .frame(width: 16, height: 16)
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.white, lineWidth: prefs.accent == choice ? 2 : 0)
                                    .padding(-3)
                            )
                            .frame(width: 22, height: 22)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help(choice.rawValue.capitalized)
                }
            }
            VStack(spacing: 6) {
                toggle("24-hour clock", $prefs.use24Hour)
                toggle("Show date", $prefs.showDate)
                toggle("Colour player from artwork", $prefs.artworkTint)
            }
            .padding(.top, 2)
        }
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Button { value.wrappedValue.toggle() } label: {
            HStack {
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer(minLength: 8)
                ZStack(alignment: value.wrappedValue ? .trailing : .leading) {
                    Capsule().fill(value.wrappedValue ? accent : Theme.fillStrong)
                    Circle().fill(.white).padding(2)
                }
                .frame(width: 26, height: 15)
                .animation(.easeOut(duration: 0.15), value: value.wrappedValue)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Theme.textTertiary)
    }
}
