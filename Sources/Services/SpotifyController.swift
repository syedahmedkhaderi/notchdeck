import AppKit
import Foundation

/// Talks to Spotify through AppleScript.
///
/// Spotify publishes the full track to the scripting dictionary, so one short
/// `osascript` call is enough to read the player and to drive it. Every entry
/// point is a no-op when Spotify is not installed, which is the normal case on
/// a Mac that only uses YouTube Music.
final class SpotifyController {
    static let shared = SpotifyController()

    struct Snapshot {
        var title = ""
        var artist = ""
        var album = ""
        var position: Double = 0
        var duration: Double = 0
        var isPlaying = false
        var artworkURL: URL?

        var hasTrack: Bool { !title.isEmpty }
    }

    static let bundleID = "com.spotify.client"
    private static let separator = "\u{1f}"

    private let lock = NSLock()
    private var installedCache: Bool?

    /// Answered once: Launch Services lookups are far too slow to run on every poll.
    var isInstalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        if let installedCache { return installedCache }
        let value = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil
        installedCache = value
        return value
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
    }

    var isAvailable: Bool { isInstalled && isRunning }

    // MARK: Reading

    func read() -> Snapshot? {
        guard isAvailable else { return nil }
        let script = """
        tell application "Spotify"
            if it is running then
                set t to name of current track
                set a to artist of current track
                set al to album of current track
                set p to player position
                set d to duration of current track
                set s to player state as text
                set u to artwork url of current track
                return t & "\u{1f}" & a & "\u{1f}" & al & "\u{1f}" & (p as text) & "\u{1f}" & (d as text) & "\u{1f}" & s & "\u{1f}" & u
            end if
        end tell
        """
        guard let output = Self.run(script) else { return nil }
        let parts = output.components(separatedBy: Self.separator)
        guard parts.count >= 7 else { return nil }

        var snapshot = Snapshot()
        snapshot.title = parts[0]
        snapshot.artist = parts[1]
        snapshot.album = parts[2]
        snapshot.position = Double(parts[3]) ?? 0
        // Spotify reports the track length in milliseconds.
        snapshot.duration = (Double(parts[4]) ?? 0) / 1000
        snapshot.isPlaying = parts[5].contains("playing")
        if !parts[6].isEmpty { snapshot.artworkURL = URL(string: parts[6]) }
        guard snapshot.hasTrack else { return nil }
        return snapshot
    }

    /// Artwork for the track currently reported by `read()`.
    func artwork(from url: URL) -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let semaphore = DispatchSemaphore(value: 0)
        var result: NSImage?
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data { result = NSImage(data: data) }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 7)
        return result
    }

    // MARK: Controls

    func next() { send("next track") }
    func previous() { send("previous track") }

    /// Starts Spotify, then starts whatever it had queued up.
    func play() {
        guard isInstalled, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        send("play")
    }

    func send(_ command: String) {
        guard isInstalled else { return }
        _ = Self.run("tell application \"Spotify\" to \(command)")
    }

    // MARK: Scripting

    @discardableResult
    private static func run(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
