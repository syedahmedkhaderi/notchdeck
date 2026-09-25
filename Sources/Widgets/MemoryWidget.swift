import SwiftUI

/// Memory read-out: how much is in use and what is holding on to it.
struct MemoryWidget: View {
    @ObservedObject var stats: StatsModel
    @Environment(\.deckAccent) private var accent

    private var sample: MemorySample { stats.memory }

    private var barColor: Color {
        switch sample.pressure {
        case .critical: return Theme.warning
        case .warning: return Color.orange
        case .normal: return accent
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeading(title: "Memory", symbol: "memorychip", trailing: StatsModel.percent(sample.usage))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(byteString(sample.used))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .monospacedDigit()
                Text("of \(byteString(sample.total))")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.top, 5)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.trackBackground)
                    Capsule().fill(barColor).frame(width: geo.size.width * min(max(sample.usage, 0), 1))
                }
            }
            .frame(height: 4)
            .padding(.top, 6)

            VStack(spacing: 3) {
                ForEach(stats.topMemory.prefix(StatsModel.topProcessCount)) { processRow($0) }
            }
            .padding(.top, 10)
        }
    }

    private func processRow(_ process: TopProcess) -> some View {
        HStack(spacing: 6) {
            Text(process.name)
                .foregroundStyle(Theme.textSecondary)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(byteString(process.memory))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
        }
        .font(.system(size: 9.5, weight: .medium))
        .lineLimit(1)
    }
}
