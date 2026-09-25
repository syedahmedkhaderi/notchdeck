import Combine
import Foundation

/// The widgets that can appear in the home deck. The raw value is what gets
/// persisted, so renaming a case would reset the user's saved order.
enum WidgetID: String, CaseIterable, Identifiable, Codable {
    case player
    case calendar
    case memory
    case battery
    case brightness
    case mirror

    var id: String { rawValue }

    var title: String {
        switch self {
        case .player: return "Music"
        case .calendar: return "Calendar"
        case .memory: return "Memory"
        case .battery: return "Battery"
        case .brightness: return "Display"
        case .mirror: return "Mirror"
        }
    }

    var symbol: String {
        switch self {
        case .player: return "music.note"
        case .calendar: return "calendar"
        case .memory: return "memorychip"
        case .battery: return "battery.75percent"
        case .brightness: return "sun.max.fill"
        case .mirror: return "web.camera"
        }
    }

    static let defaultOrder: [WidgetID] = [.player, .calendar, .memory, .battery, .brightness, .mirror]
}

/// Remembers the left-to-right order of the home widgets and which are hidden.
final class WidgetOrder: ObservableObject {
    private static let key = "widgetOrder"
    private static let hiddenKey = "hiddenWidgets"

    @Published private(set) var order: [WidgetID]
    @Published private(set) var hidden: Set<WidgetID>

    var visible: [WidgetID] { order.filter { !hidden.contains($0) } }

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        var seen = Set<WidgetID>()
        var restored: [WidgetID] = []
        for raw in stored {
            guard let id = WidgetID(rawValue: raw), seen.insert(id).inserted else { continue }
            restored.append(id)
        }
        // A widget added in a later build lands at the end instead of vanishing.
        for id in WidgetID.defaultOrder where seen.insert(id).inserted {
            restored.append(id)
        }
        order = restored
        hidden = Set((UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? []).compactMap(WidgetID.init))
    }

    func isVisible(_ id: WidgetID) -> Bool { !hidden.contains(id) }

    func move(_ id: WidgetID, by offset: Int) {
        guard let index = order.firstIndex(of: id) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        save()
    }

    /// The last visible widget cannot be hidden, so the deck is never empty.
    func toggle(_ id: WidgetID) {
        if hidden.contains(id) {
            hidden.remove(id)
        } else if visible.count > 1 {
            hidden.insert(id)
        }
        save()
    }

    func reset() {
        order = WidgetID.defaultOrder
        hidden = []
        save()
    }

    private func save() {
        UserDefaults.standard.set(order.map(\.rawValue), forKey: Self.key)
        UserDefaults.standard.set(hidden.map(\.rawValue), forKey: Self.hiddenKey)
    }
}
