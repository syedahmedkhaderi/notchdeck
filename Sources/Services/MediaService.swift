import AppKit
import Combine
import Foundation

enum MediaSource {
    case youtubeMusic
    case spotify

    var name: String {
        switch self {
        case .youtubeMusic: return "YouTube Music"
        case .spotify: return "Spotify"
        }
    }
}

struct NowPlaying {
    var title = ""
    var artist = ""
    var album = ""
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0
    var artwork: NSImage?
    /// Dominant colour of the artwork, computed once per cover.
    var tint: NSColor?
    var source: MediaSource = .youtubeMusic
    /// YouTube Music's Like state; nil when the player shows no Like control.
    var liked: Bool?

    var hasTrack: Bool { !title.isEmpty }
    var sourceName: String { source.name }

    /// Everything the player shows except the playhead, which is interpolated
    /// locally. Used to skip publishing when a poll found nothing new.
    func sameDisplay(as other: NowPlaying) -> Bool {
        title == other.title && artist == other.artist && album == other.album
            && isPlaying == other.isPlaying && duration == other.duration
            && artwork === other.artwork && source == other.source && liked == other.liked
    }
}

/// Drives the panel's player.
///
/// YouTube Music is the default and the one that is exercised hardest: it is
/// read and controlled through its accessibility tree, because the system
/// now-playing service no longer hands out metadata on this macOS version.
/// Spotify is supported in parallel through AppleScript when it is installed and
/// running, so whichever of the two is actually playing wins.
final class MediaService: ObservableObject {
    @Published private(set) var now = NowPlaying()
    @Published private(set) var launching = false
    @Published private(set) var needsPermission = false

    private var timer: Timer?
    /// After a command (or while the player is still attaching) the player is
    /// polled faster so the new state lands quickly.
    private var fastUntil = Date.distantPast
    private var sampledAt = Date()
    private var elapsedAtSample: Double = 0
    private var rate: Double = 0
    private var artworkKey = ""
    private var spotifyArtworkInFlight = ""
    private var busy = false
    /// A refresh was asked for while a poll was in flight; run it straight after.
    private var refreshPending = false
    private var launchToken = 0
    private var lastCommand = Date.distantPast
    /// Chrome takes a beat to flip its buttons after a press. Until a poll
    /// confirms the state the user asked for (or this deadline passes), polls
    /// that still show the old state are overridden instead of flickering back.
    private var expectedPlaying: Bool?
    private var expectedLiked: Bool?
    private var expectedUntil = Date.distantPast
    /// Title of the track a skip left. Until the player shows a new track, polls
    /// still carrying the old one (and its old playhead) are ignored.
    private var skippingFrom: String?
    private var skipUntil = Date.distantPast
    private var lastGoodRead = Date.distantPast
    private var active = false
    private var spotifyObserver: NSObjectProtocol?

    private let queue = DispatchQueue(label: "notchdeck.media", qos: .userInitiated)

    var isAvailable: Bool { YouTubeMusicAX.isAppRunning || SpotifyController.shared.isAvailable }

    // MARK: Lifecycle

    func start() {
        guard !active else { return }
        active = true
        YouTubeMusicAX.shared.wake()
        fastUntil = Date().addingTimeInterval(3)
        // Spotify announces every change itself, so it never has to be polled fast.
        spotifyObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        pollSoon(after: 0)
    }

    func stop() {
        active = false
        timer?.invalidate()
        timer = nil
        if let spotifyObserver { DistributedNotificationCenter.default().removeObserver(spotifyObserver) }
        spotifyObserver = nil
    }

    /// One self-rescheduling timer: quick right after a command, then a steady
    /// once-a-second tick (each read is a few milliseconds of AX traffic).
    private func pollSoon(after delay: Double) {
        guard active else { return }
        timer?.invalidate()
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.pollSoon(after: Date() < self.fastUntil ? 0.3 : 1.0)
        }
        t.tolerance = delay * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Polling

    func refresh() {
        guard !busy else {
            refreshPending = true
            return
        }
        busy = true
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = self.probe()
            DispatchQueue.main.async {
                self.busy = false
                self.apply(snapshot)
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    private struct Probe {
        var youtube: YouTubeMusicAX.Snapshot?
        var spotify: SpotifyController.Snapshot?
        var trusted = true
        var youtubeRunning = false
    }

    /// Reads both players. Each reader answers nil straight away when its app
    /// is not running, so an idle player costs almost nothing.
    private func probe() -> Probe {
        var result = Probe()
        result.trusted = YouTubeMusicAX.isTrusted
        result.youtubeRunning = YouTubeMusicAX.isAppRunning
        result.youtube = YouTubeMusicAX.shared.read()
        result.spotify = SpotifyController.shared.read()
        return result
    }

    private func apply(_ probe: Probe) {
        let permission = !probe.trusted && probe.youtubeRunning
        if needsPermission != permission { needsPermission = permission }

        // Chrome drops its tree for a moment when it rebuilds the page. One
        // empty read while the app is still up is not "nothing playing".
        if probe.youtube == nil, probe.spotify == nil, probe.youtubeRunning, now.hasTrack,
           Date().timeIntervalSince(lastGoodRead) < 4 {
            return
        }
        if probe.youtube != nil || probe.spotify != nil { lastGoodRead = Date() }

        var track = Self.pick(youtube: probe.youtube, spotify: probe.spotify)

        // Right after a skip the bar still shows the old track for a moment;
        // showing it would throw the playhead back to where the old song was.
        // "Previous" early in a track restarts it, which reads as a playhead near 0.
        if let from = skippingFrom {
            if Date() < skipUntil, track.title == from, track.position > 3 { return }
            skippingFrom = nil
        }

        let sameTrack = track.hasTrack && track.title == now.title && track.source == now.source
        if Date() < expectedUntil, sameTrack {
            if let expected = expectedPlaying {
                if track.isPlaying == expected {
                    expectedPlaying = nil
                } else {
                    track.isPlaying = expected
                    track.position = livePosition()
                }
            }
            if let expected = expectedLiked {
                if track.liked == expected { expectedLiked = nil } else { track.liked = expected }
            }
        } else {
            expectedPlaying = nil
            expectedLiked = nil
        }

        // A seek done in the player itself moves the playhead without changing
        // anything else, so drift is a reason to publish too.
        let drifted = track.hasTrack && abs(track.position - livePosition()) > 1.5
        if track.hasTrack {
            sampledAt = Date()
            elapsedAtSample = track.position
            rate = track.isPlaying ? 1 : 0
        } else {
            rate = 0
        }
        resolveArtwork(&track, spotify: track.source == .spotify ? probe.spotify : nil)
        if drifted || !track.sameDisplay(as: now) { now = track }
    }

    /// Whichever player is actually running the audio wins; a paused YouTube
    /// Music still beats a paused Spotify because it is the panel's default.
    private static func pick(youtube: YouTubeMusicAX.Snapshot?, spotify: SpotifyController.Snapshot?) -> NowPlaying {
        var track = NowPlaying()
        if let youtube, youtube.isPlaying || !(spotify?.isPlaying ?? false) {
            track.source = .youtubeMusic
            track.title = youtube.title
            track.artist = youtube.artist
            track.album = youtube.album
            track.duration = youtube.duration
            track.position = youtube.position
            track.isPlaying = youtube.isPlaying
            track.liked = youtube.liked
        } else if let spotify {
            track.source = .spotify
            track.title = spotify.title
            track.artist = spotify.artist
            track.album = spotify.album
            track.duration = spotify.duration
            track.position = spotify.position
            track.isPlaying = spotify.isPlaying
        }
        return track
    }

    // MARK: Artwork

    /// YouTube Music's accessibility tree carries no pixels, so the cover is
    /// looked up in the public catalogue; Spotify serves its own artwork URL.
    private func resolveArtwork(_ track: inout NowPlaying, spotify: SpotifyController.Snapshot?) {
        guard track.hasTrack else { artworkKey = ""; return }
        let key = ArtworkService.key(title: track.title, artist: track.artist)
        if artworkKey == key, let artwork = now.artwork {
            track.artwork = artwork
            track.tint = now.tint
            return
        }
        artworkKey = key

        if let image = ArtworkService.shared.cached(key) {
            track.artwork = image
            track.tint = Self.dominantColor(of: image)
            return
        }
        if let url = spotify?.artworkURL {
            // Downloads share the queue that sends play/pause, so only one at a time.
            guard spotifyArtworkInFlight != key else { return }
            spotifyArtworkInFlight = key
            queue.async { [weak self] in
                let image = SpotifyController.shared.artwork(from: url)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.spotifyArtworkInFlight = ""
                    guard let image, self.artworkKey == key else { return }
                    self.now.artwork = image
                    self.now.tint = Self.dominantColor(of: image)
                }
            }
            return
        }
        ArtworkService.shared.artwork(title: track.title, artist: track.artist) { [weak self] image in
            guard let self, let image, self.artworkKey == key else { return }
            self.now.artwork = image
            self.now.tint = Self.dominantColor(of: image)
        }
    }

    /// Averages the cover down to one pixel, then lifts it so it reads on black.
    static func dominantColor(of image: NSImage) -> NSColor? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let color = NSColor(red: CGFloat(pixel[0]) / 255, green: CGFloat(pixel[1]) / 255,
                            blue: CGFloat(pixel[2]) / 255, alpha: 1)
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        // Near-grey covers would give a muddy tint; fall back to the accent.
        guard sat > 0.12 else { return nil }
        return NSColor(hue: h, saturation: min(max(sat, 0.45), 0.8), brightness: max(b, 0.85), alpha: 1)
    }

    /// Interpolated playhead so the scrubber moves smoothly between polls.
    func livePosition() -> Double {
        guard now.hasTrack else { return 0 }
        let extra = rate > 0 ? Date().timeIntervalSince(sampledAt) * rate : 0
        return min(elapsedAtSample + extra, max(now.duration, 0))
    }

    // MARK: Controls

    /// Every command returns immediately: the UI flips first, the press runs
    /// on a background queue, and a refresh confirms it shortly after.
    func playPause() {
        guard acceptCommand() else { return }
        guard now.hasTrack else {
            openAndPlay()
            return
        }
        let wasPlaying = now.isPlaying
        switch now.source {
        case .spotify:
            queue.async { SpotifyController.shared.send(wasPlaying ? "pause" : "play") }
        case .youtubeMusic:
            YouTubeMusicAX.shared.press(wasPlaying ? .pause : .play) { ok in
                if !ok { MediaRemote.shared.send(wasPlaying ? .pause : .play) }
            }
        }
        let position = livePosition()
        now.isPlaying = !wasPlaying
        sampledAt = Date()
        elapsedAtSample = position
        rate = now.isPlaying ? 1 : 0
        expectedPlaying = now.isPlaying
        expectedUntil = Date().addingTimeInterval(2)
        confirmSoon()
    }

    func next() { skip(.next) }
    func previous() { skip(.previous) }

    private func skip(_ control: YouTubeMusicAX.Control) {
        guard acceptCommand(), now.hasTrack else { return }
        switch now.source {
        case .spotify:
            queue.async {
                if control == .next { SpotifyController.shared.next() } else { SpotifyController.shared.previous() }
            }
        case .youtubeMusic:
            YouTubeMusicAX.shared.press(control) { ok in
                if !ok { MediaRemote.shared.send(control == .next ? .nextTrack : .previousTrack) }
            }
        }
        // Restart the playhead right away so the skip feels instant.
        skippingFrom = now.title
        skipUntil = Date().addingTimeInterval(3)
        expectedPlaying = nil
        sampledAt = Date()
        elapsedAtSample = 0
        now.position = 0
        confirmSoon()
    }

    /// Likes or un-likes the current YouTube Music track.
    func toggleLike() {
        guard acceptCommand(), now.hasTrack, now.source == .youtubeMusic, let liked = now.liked else { return }
        YouTubeMusicAX.shared.press(.like)
        now.liked = !liked
        expectedLiked = !liked
        expectedUntil = Date().addingTimeInterval(2)
        confirmSoon()
    }

    /// Brings the playing app to the front.
    func openPlayer() {
        if now.source == .spotify, now.hasTrack,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: SpotifyController.bundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        } else {
            YouTubeMusicAX.open()
        }
    }

    /// Swallows only a genuine double-fire of the same click.
    private func acceptCommand() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastCommand) > 0.25 else { return false }
        lastCommand = now
        return true
    }

    /// Polls quickly for a couple of seconds so the new state or track lands fast.
    private func confirmSoon() {
        fastUntil = Date().addingTimeInterval(2.5)
        if active {
            pollSoon(after: 0.3)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
        }
    }

    // MARK: Launch and play

    /// Brings YouTube Music up, starts whatever it has queued, and keeps trying
    /// until the audio is really running.
    func openAndPlay() {
        guard !launching else { return }
        launching = true
        launchToken += 1
        let token = launchToken

        YouTubeMusicAX.open()
        YouTubeMusicAX.shared.wake()
        fastUntil = Date().addingTimeInterval(30)
        if !YouTubeMusicAX.isTrusted { YouTubeMusicAX.requestTrust() }
        attemptLaunch(token: token, count: 0)
    }

    private func attemptLaunch(token: Int, count: Int) {
        guard token == launchToken else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let snapshot = YouTubeMusicAX.shared.read()
            DispatchQueue.main.async {
                guard token == self.launchToken else { return }

                if let snapshot, snapshot.hasTrack, snapshot.isPlaying {
                    self.launching = false
                    self.refresh()
                    return
                }
                // The player bar is up but silent: ask for play. YouTube Music
                // restores the last track when it starts, so this normally lands.
                // The press is spaced out because the accessibility tree takes a
                // moment to catch up, and pressing twice in a row cancels out.
                if let snapshot, snapshot.hasTrack, count >= 3, (count - 3) % 6 == 0 {
                    YouTubeMusicAX.shared.press(.play)
                }
                guard count < 40 else {
                    self.launching = false
                    self.refresh()
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.attemptLaunch(token: token, count: count + 1)
                }
            }
        }
    }
}
