import SwiftUI

struct CalendarWidget: View {
    @ObservedObject var calendar: CalendarService
    @Environment(\.deckAccent) private var accent

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetHeading(title: Self.monthFormatter.string(from: Date()), symbol: "calendar")

            Group {
                if calendar.today.isEmpty {
                    emptyState
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(calendar.today.prefix(2)) { eventRow($0) }
                    }
                }
            }
            .padding(.top, 9)

            Spacer(minLength: 4)
            weekStrip
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if calendar.authorized {
            Text("Nothing scheduled today")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        } else {
            Button(action: calendar.openPrivacySettings) {
                HStack(spacing: 4) {
                    Text("Allow calendar access")
                    Image(systemName: "arrow.up.right").font(.system(size: 8, weight: .bold))
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(accent)
            }
            .buttonStyle(.plain)
        }
    }

    private func eventRow(_ event: CalendarEvent) -> some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(Color(nsColor: event.calendarColor))
                .frame(width: 3, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(event.isAllDay ? "All day" : "\(Self.timeFormatter.string(from: event.start)) – \(Self.timeFormatter.string(from: event.end))")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
        }
    }

    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(calendar.weekDays(), id: \.number) { day in
                VStack(spacing: 3) {
                    Text(day.label)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundStyle(day.isToday ? Theme.textPrimary : Theme.textTertiary)
                    Text(day.number)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(day.isToday ? Color.black : Theme.textSecondary)
                        .frame(width: 22, height: 20)
                        .background(Circle().fill(day.isToday ? accent : .clear))
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}
