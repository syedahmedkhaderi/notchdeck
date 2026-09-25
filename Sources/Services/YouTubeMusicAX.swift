import AppKit
import ApplicationServices

/// Reads and drives the YouTube Music player through its accessibility tree.
///
/// Since macOS 15.4 the system refuses to hand now-playing metadata to apps
/// without an Apple-granted entitlement, so the private MediaRemote service
/// returns nothing on this machine. The browser does publish its player bar to
/// assistive clients though, so the panel reads the current track and presses
/// the transport buttons that way instead.
///
/// All traffic is funnelled through one serial queue: Chrome's accessibility
/// tree is built lazily and answers much faster when it is only ever queried by
/// a single caller.
final class YouTubeMusicAX {
    static let shared = YouTubeMusicAX()

    struct Snapshot {
        var title = ""
        var artist = ""
        var album = ""
        var position: Double = 0
        var duration: Double = 0
        var isPlaying = false

        var hasTrack: Bool { !title.isEmpty }
    }

    /// Chrome app ids for the installed YouTube Music app.
    static let appBundleIDs = [
        "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod",
        "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod.Stable"
    ]
    static let webURL = URL(string: "https://music.youtube.com")!

    private static let timePattern = try! NSRegularExpression(pattern: "^(\\d+):(\\d{2}) / (\\d+):(\\d{2})$")

    private let queue = DispatchQueue(label: "notchdeck.youtube.ax", qos: .userInitiated)
    private var appElement: AXUIElement?
    private var pid: pid_t = 0
    private var bar: AXUIElement?
    private var lastAttach = Date.distantPast
    private var lastNudge = Date.distantPast
    private var warmedUp = false
    /// Transport buttons seen on the last read, so a press never has to walk
    /// the tree again.
    private var buttons: [String: AXUIElement] = [:]

    enum Control: String {
        case play = "Play", pause = "Pause", next = "Next", previous = "Previous"
    }

    private init() {
        // Chrome can stall for seconds while it rebuilds a page; never let a
        // single query hang for the system default of about six seconds.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.6)
    }

    // MARK: Permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: Availability

    /// The running YouTube Music app, if any.
    static func runningApp() -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        if let exact = apps.first(where: { appBundleIDs.contains($0.bundleIdentifier ?? "") }) { return exact }
        return apps.first { ($0.localizedName ?? "").localizedCaseInsensitiveContains("youtube music") }
    }

    static var isAppRunning: Bool { runningApp() != nil }

    static var applicationURL: URL? {
        for id in appBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/Chrome Apps.localized/YouTube Music.app")
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Brings YouTube Music to the front, launching it when it is not running.
    static func open() {
        guard let url = applicationURL else {
            NSWorkspace.shared.open(webURL)
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    // MARK: Reading

    /// One pass over the player bar. Returns nil when YouTube Music has nothing loaded.
    func read() -> Snapshot? {
        queue.sync { readLocked() }
    }

    private func readLocked() -> Snapshot? {
        guard Self.isTrusted, let app = Self.runningApp() else {
            resetLocked()
            return nil
        }
        if app.processIdentifier != pid {
            resetLocked()
            appElement = AXUIElementCreateApplication(app.processIdentifier)
            pid = app.processIdentifier
            lastAttach = .distantPast
        }
        // A page rebuild leaves the cached bar stale; find the new one in the
        // same pass instead of reporting "nothing playing" for a poll.
        if let cached = bar, !isAlive(cached) {
            bar = nil
            buttons = [:]
            lastAttach = .distantPast
        }
        if bar == nil, Date().timeIntervalSince(lastAttach) > 1.0 {
            lastAttach = Date()
            _ = attachLocked()
            if bar != nil { warmedUp = true }
        }
        guard let bar else { return nil }

        var scan = Scan()
        collect(bar, 0, &scan)
        buttons = scan.buttons

        var snapshot = Snapshot()
        snapshot.title = scan.heading
        for text in scan.texts where Self.parseTime(text) == nil {
            if snapshot.title.isEmpty { snapshot.title = text; continue }
            if text == snapshot.title { continue }
            snapshot.artist += text
        }
        if snapshot.title.isEmpty { return nil }
        // During a track change the bar can briefly pair the old track's time
        // with the new one's length; clamp so the playhead never jumps past the end.
        if let (position, duration) = scan.time {
            snapshot.position = min(position, duration)
            snapshot.duration = duration
        }
        if let progress = scan.progress, snapshot.duration > 0, snapshot.position == 0 {
            snapshot.position = progress * snapshot.duration
        }
        snapshot.isPlaying = scan.hasPause
        Self.split(&snapshot)
        return snapshot
    }

    private struct Scan {
        var heading = ""
        var texts: [String] = []
        var time: (Double, Double)?
        var progress: Double?
        var plays = false
        var pauses = false
        var nexts = false
        var previouses = false
        var buttons: [String: AXUIElement] = [:]

        var hasPause: Bool { pauses }
    }

    private func collect(_ element: AXUIElement, _ depth: Int, _ scan: inout Scan) {
        guard depth < 8 else { return }
        switch Self.string(element, kAXRoleAttribute) {
        case "AXStaticText":
            let value = Self.string(element, kAXValueAttribute)
            if !value.isEmpty {
                scan.texts.append(value)
                if let parsed = Self.parseTime(value) { scan.time = parsed }
            }
        case "AXHeading":
            if scan.heading.isEmpty {
                let title = Self.string(element, kAXTitleAttribute)
                let value = Self.string(element, kAXValueAttribute)
                scan.heading = title.isEmpty ? value : title
            }
        case "AXProgressIndicator":
            if scan.progress == nil, let number = Self.attribute(element, kAXValueAttribute) as? NSNumber {
                scan.progress = number.doubleValue > 1 ? number.doubleValue / 100 : number.doubleValue
            }
        case "AXButton":
            let title = Self.string(element, kAXTitleAttribute)
            switch title {
            case "Play", "Pause", "Next", "Previous": scan.buttons[title] = element
            default: break
            }
            switch title {
            case "Play": scan.plays = true
            case "Pause": scan.pauses = true
            case "Next": scan.nexts = true
            case "Previous": scan.previouses = true
            default: break
            }
        default:
            break
        }
        for child in Self.children(element) { collect(child, depth + 1, &scan) }
    }

    /// The artist line arrives as "artist • album • year"; split it apart.
    private static func split(_ snapshot: inout Snapshot) {
        let parts = snapshot.artist
            .components(separatedBy: " • ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        snapshot.artist = parts[0]
        if parts.count > 1 { snapshot.album = parts[1] }
    }

    private static func parseTime(_ text: String) -> (Double, Double)? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = timePattern.firstMatch(in: text, range: range), match.numberOfRanges == 5 else { return nil }
        func group(_ index: Int) -> Double {
            guard let r = Range(match.range(at: index), in: text) else { return 0 }
            return Double(text[r]) ?? 0
        }
        return (group(1) * 60 + group(2), group(3) * 60 + group(4))
    }

    // MARK: Controls

    /// Presses a transport button without stealing focus. Runs on the AX queue,
    /// never the caller's thread, so a slow Chrome can't freeze the panel.
    func press(_ control: Control, completion: ((Bool) -> Void)? = nil) {
        queue.async {
            let ok = self.pressLocked(control)
            if let completion { DispatchQueue.main.async { completion(ok) } }
        }
    }

    /// Play and pause act on intent, not as a toggle: YouTube Music uses one
    /// button whose title flips, so the live title is checked first. If it
    /// already says the opposite, the player is in the wanted state and
    /// pressing would invert it.
    private func pressLocked(_ control: Control) -> Bool {
        let opposite: String? = control == .play ? "Pause" : control == .pause ? "Play" : nil
        for cached in buttons.values {
            let title = Self.string(cached, kAXTitleAttribute)
            if title == control.rawValue { return perform(cached) }
            if let opposite, title == opposite { return true }
        }
        // The cached buttons went stale; search the bar.
        guard let bar, isAlive(bar) else { return false }
        if press(in: bar, titled: control.rawValue) { return true }
        if let opposite, find(in: bar, titled: opposite) { return true }
        return false
    }

    private func find(in element: AXUIElement, titled title: String, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        if Self.string(element, kAXRoleAttribute) == "AXButton",
           Self.string(element, kAXTitleAttribute) == title { return true }
        return Self.children(element).contains { find(in: $0, titled: title, depth: depth + 1) }
    }

    private func perform(_ element: AXUIElement) -> Bool {
        AXUIElementPerformAction(element, kAXPressAction as CFString) == .success
    }

    /// Finds a transport button by its accessibility title and presses it.
    private func press(in element: AXUIElement, titled title: String, depth: Int = 0) -> Bool {
        guard depth < 8 else { return false }
        if Self.string(element, kAXRoleAttribute) == "AXButton",
           Self.string(element, kAXTitleAttribute) == title {
            return perform(element)
        }
        for child in Self.children(element) {
            if press(in: child, titled: title, depth: depth + 1) { return true }
        }
        return false
    }

    func reset() { queue.sync { resetLocked() } }

    private func resetLocked() {
        appElement = nil
        pid = 0
        bar = nil
        buttons = [:]
        warmedUp = false
        lastAttach = .distantPast
        lastNudge = .distantPast
    }

    // MARK: Attaching

    /// Finds the player bar inside the app's windows, warming up Chrome's
    /// accessibility tree (which starts empty and fills in after a few queries).
    private func attachLocked() -> Bool {
        guard let appElement else { return false }
        // Chrome keeps its accessibility tree switched off until a client asks
        // for it, so the panel announces itself as an assistive client. Chrome
        // forgets after a quiet spell, hence the periodic re-announcement.
        if !warmedUp, Date().timeIntervalSince(lastNudge) > 5 {
            lastNudge = Date()
            _ = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        }
        guard let windows = Self.attribute(appElement, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
            return false
        }
        for window in Self.ordered(windows) {
            if let found = Self.findPlayerBar(window, 0), isAlive(found) {
                bar = found
                return true
            }
        }
        bar = nil
        return false
    }

    /// The main window first: the app also owns tiny helper windows.
    private static func ordered(_ windows: [AXUIElement]) -> [AXUIElement] {
        windows.sorted { lhs, rhs in
            area(lhs) > area(rhs)
        }
    }

    private static func area(_ window: AXUIElement) -> CGFloat {
        guard let positionRef = attribute(window, kAXPositionAttribute),
              let sizeRef = attribute(window, kAXSizeAttribute) else { return 0 }
        let position = unsafeBitCast(positionRef, to: AXValue.self)
        let size = unsafeBitCast(sizeRef, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(position) == .cgPoint, AXValueGetType(size) == .cgSize else { return 0 }
        AXValueGetValue(position, .cgPoint, &point)
        AXValueGetValue(size, .cgSize, &dimensions)
        return dimensions.width * dimensions.height
    }

    /// The player bar lives about eleven levels down Chrome's window tree, so the
    /// ceiling has to leave room for the page growing a little.
    private static func findPlayerBar(_ element: AXUIElement, _ depth: Int) -> AXUIElement? {
        guard depth < 24 else { return nil }
        if string(element, kAXRoleAttribute) == "AXToolbar",
           string(element, kAXTitleAttribute) == "Player bar" { return element }
        for child in children(element) {
            if let found = findPlayerBar(child, depth + 1) { return found }
        }
        return nil
    }

    /// A cached element goes stale when Chrome rebuilds the page.
    private func isAlive(_ element: AXUIElement) -> Bool {
        var out: AnyObject?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &out) == .success
    }

    // MARK: AX helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var out: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &out) == .success ? out : nil
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String {
        (attribute(element, name) as? String) ?? ""
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }
}
