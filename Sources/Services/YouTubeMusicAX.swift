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
        /// Nil when the bar shows no Like control (e.g. an ad).
        var liked: Bool?

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
    private var attachDelay: TimeInterval = 0
    private var lastNudge = Date.distantPast
    private var warmedUp = false
    /// Transport buttons seen on the last read, so a press never has to walk
    /// the tree again.
    private var buttons: [String: AXUIElement] = [:]

    enum Control: String {
        case play = "Play", pause = "Pause", next = "Next", previous = "Previous", like = "Like"
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
        }
        // A page rebuild leaves the cached bar stale; find the new one in the
        // same pass instead of reporting "nothing playing" for a poll.
        if let cached = bar, !isAlive(cached) {
            bar = nil
            buttons = [:]
            attachDelay = 0
        }
        // Attaching walks thousands of elements, so while nothing is loaded
        // (no window, or an empty player) the retries back off to every 8 s.
        if bar == nil, Date().timeIntervalSince(lastAttach) > attachDelay {
            lastAttach = Date()
            if attachLocked() {
                warmedUp = true
                attachDelay = 1
            } else {
                attachDelay = min(max(attachDelay * 2, 1), 8)
            }
        }
        guard let bar else { return nil }

        var scan = Scan()
        collect(bar, 0, &scan)
        buttons = scan.buttons

        var snapshot = Snapshot()
        snapshot.title = scan.heading.isEmpty ? scan.texts.first(where: { Self.parseTime($0) == nil }) ?? "" : scan.heading
        if snapshot.title.isEmpty { return nil }
        Self.parseByline(scan.byline, into: &snapshot)

        // The time label is what the user sees; the seek slider (in seconds)
        // covers the moments the label is missing during a page rebuild.
        if let (position, duration) = scan.time, duration > 0 {
            snapshot.duration = duration
            snapshot.position = position
        } else if let (value, maximum) = scan.seek, maximum > 0 {
            snapshot.duration = maximum
            snapshot.position = value
        }
        // During a track change the bar can briefly pair the old track's time
        // with the new one's length; clamp so the playhead never jumps past the end.
        snapshot.position = min(max(snapshot.position, 0), snapshot.duration)
        snapshot.isPlaying = scan.pauses
        snapshot.liked = scan.liked
        return snapshot
    }

    /// Makes the next read retry attaching right away, e.g. when the panel opens.
    func wake() { queue.async { self.attachDelay = 0 } }

    private struct Scan {
        var heading = ""
        var byline = ""
        var texts: [String] = []
        var time: (Double, Double)?
        var seek: (Double, Double)?
        var pauses = false
        var liked: Bool?
        var buttons: [String: AXUIElement] = [:]
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
            // The heading's value is its level ("2"), never the track name.
            if scan.heading.isEmpty { scan.heading = Self.string(element, kAXTitleAttribute) }
        case "AXGroup":
            // "Artist • Album • Year" is published whole as the group's title.
            if scan.byline.isEmpty {
                let title = Self.string(element, kAXTitleAttribute)
                if title.contains(" • ") {
                    scan.byline = title
                    return
                }
            }
        case "AXProgressIndicator":
            if scan.seek == nil, Self.string(element, kAXTitleAttribute) == "Seek slider",
               let value = Self.attribute(element, kAXValueAttribute) as? NSNumber,
               let maximum = Self.attribute(element, kAXMaxValueAttribute) as? NSNumber {
                scan.seek = (value.doubleValue, maximum.doubleValue)
            }
            return
        case "AXButton":
            let title = Self.string(element, kAXTitleAttribute)
            switch title {
            case "Play", "Pause", "Next", "Previous": scan.buttons[title] = element
            default: break
            }
            if title == "Pause" { scan.pauses = true }
            return
        case "AXCheckBox":
            if Self.string(element, kAXTitleAttribute) == "Like" {
                scan.buttons["Like"] = element
                scan.liked = (Self.attribute(element, kAXValueAttribute) as? NSNumber)?.boolValue ?? false
            }
            return
        default:
            break
        }
        for child in Self.children(element) { collect(child, depth + 1, &scan) }
    }

    /// Songs read "artist • album • year"; videos read "artist • 1.2M views •
    /// 30K likes", where the second part is not an album.
    private static func parseByline(_ byline: String, into snapshot: inout Snapshot) {
        let parts = byline
            .components(separatedBy: "•")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let artist = parts.first else { return }
        snapshot.artist = artist
        if parts.count > 1 {
            let second = parts[1]
            let lowered = second.lowercased()
            let isYear = second.count == 4 && Int(second) != nil
            if !isYear, !lowered.hasSuffix("views"), !lowered.hasSuffix("likes") { snapshot.album = second }
        }
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
        let role = Self.string(element, kAXRoleAttribute)
        if role == "AXButton" || role == "AXCheckBox",
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
        attachDelay = 0
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
