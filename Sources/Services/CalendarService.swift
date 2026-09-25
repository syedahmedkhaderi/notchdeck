import AppKit
import Combine
import EventKit
import Foundation

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarColor: NSColor
}

/// Today's events plus the current week strip.
final class CalendarService: ObservableObject {
    @Published private(set) var today: [CalendarEvent] = []
    @Published private(set) var authorized = false

    private let store = EKEventStore()
    private var timer: Timer?

    func start() {
        requestAccess()
    }

    /// The timer only runs while the panel is on screen.
    func setActive(_ active: Bool) {
        guard active else {
            timer?.invalidate()
            timer = nil
            return
        }
        reload()
        guard timer == nil else { return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.reload() }
        t.tolerance = 20
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Opens System Settings so the user can turn calendar access back on.
    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        NSWorkspace.shared.open(url)
    }

    private func requestAccess() {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess {
            authorized = true
            reload()
            return
        }
        guard status == .notDetermined else { return }
        store.requestFullAccessToEvents { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.authorized = granted
                self?.reload()
            }
        }
    }

    func reload() {
        guard authorized else { return }
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        guard let end = cal.date(byAdding: .day, value: 1, to: start) else { return }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let matches: [EKEvent] = store.events(matching: predicate)
        let sorted = matches.sorted { $0.startDate < $1.startDate }
        today = sorted.map { event in
            CalendarEvent(
                id: event.eventIdentifier ?? UUID().uuidString,
                title: event.title ?? "Untitled",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                calendarColor: event.calendar?.color ?? NSColor.systemTeal
            )
        }
    }

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return f
    }()

    /// Five day cells centred on today.
    func weekDays() -> [(date: Date, label: String, number: String, isToday: Bool)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (-2...2).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: offset, to: today) else { return nil }
            return (date, Self.dayLabel.string(from: date), String(cal.component(.day, from: date)), offset == 0)
        }
    }
}
