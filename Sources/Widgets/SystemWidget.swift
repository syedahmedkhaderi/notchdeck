import SwiftUI

/// Battery detail.
struct SystemWidget: View {
    @ObservedObject var stats: StatsModel
    @Environment(\.deckAccent) private var accent

    private var battery: BatterySample { stats.battery }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeading(title: "Battery", symbol: symbol)

            Text(StatsModel.percent(battery.level))
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .foregroundStyle(battery.level <= 0.15 && !battery.onAC ? Theme.warning : Theme.textPrimary)
                .monospacedDigit()
                .padding(.top, 1)

            Text(status)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(battery.isCharging || battery.isCharged ? accent : Theme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            VStack(spacing: 1) {
                keyValue("Time", battery.minutesRemaining.map(StatsModel.durationString) ?? "–")
                keyValue("Health", battery.health.map { "\($0)%" } ?? "–")
                keyValue("Cycles", battery.cycles.map(String.init) ?? "–")
                keyValue("Temp", battery.temperature.map { String(format: "%.1f°", $0) } ?? "–")
                keyValue("Power", battery.power.map { String(format: "%.1f W", $0) } ?? "–")
            }
            .padding(.top, 5)
        }
    }

    private var symbol: String {
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.level {
        case ..<0.13: return "battery.0percent"
        case ..<0.38: return "battery.25percent"
        case ..<0.63: return "battery.50percent"
        case ..<0.88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private var status: String {
        if let watts = battery.adapterWatts, battery.onAC { return "\(battery.statusText) · \(watts)W" }
        return battery.statusText
    }

    private func keyValue(_ label: String, _ value: String) -> some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 1)
            Text(value).foregroundStyle(Theme.textPrimary).monospacedDigit()
        }
        .font(.system(size: 9.5, weight: .medium))
        .lineLimit(1)
        .frame(height: 12)
    }
}
