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

    var hasTrack: Bool { !title.isEmpty }
    var sourceName: String { source.name }

    /// Everything the player shows except the playhead, which is interpolated
    /// locally. Used to skip publishing when a poll found nothing new.
    func sameDisplay(as other: NowPlaying) -> Bool {
        title == other.title && artist == other.artist && album == other.album
            && isPlaying == other.isPlaying && duration == other.duration
            && artwork === other.artwork && source == other.source
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
    /// While the panel is warming up (or right after a launch) the player is
    /// polled faster, because Chrome only publishes its accessibility tree after
    /// a few rounds of queries.
    private var fastUntil = Date.distantPast
    private var sampledAt = Date()
    private var elapsedAtSample: Double = 0
    private var rate: Double = 0
    private var artworkKey = ""
    private var busy = false
    /// A refresh was asked for while a poll was in flight; run it straight after.
    private var refreshPending = false
    private var launchToken = 0
    private var lastCommand = Date.distantPast
    /// Polls that started before this moment (plus Chrome's lag) can't have
    /// seen the last command yet, so their play state is ignored.
    private var commandAt = Date.distantPast
    private var lastGoodRead = Date.distantPast
    private var active = false

    private let queue = DispatchQueue(label: "notchdeck.media", qos: .userInitiated)

    var isAvailable: Bool { YouTubeMusicAX.isAppRunning || SpotifyController.shared.isAvailable }

    // MARK: Lifecycle

    func start() {
        guard !active else { return }
        active = true
        pollSoon(after: 0, fast: true)
    }

    func stop() {
        active = false
        timer?.invalidate()
        timer = nil
    }

    /// One self-rescheduling timer: quick while the panel is settling, then a
    /// steady once-a-second tick.
    private func pollSoon(after delay: Double, fast: Bool = false) {
        guard active else { return }
        timer?.invalidate()
        if fast { fastUntil = Date().addingTimeInterval(8) }
        let t = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.refresh()
            self.pollSoon(after: Date() < self.fastUntil ? 0.35 : 1.5)
        }
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
        let startedAt = Date()
        queue.async { [weak self] in
            guard let self else { return }
            var snapshot = self.probe()
            snapshot.startedAt = startedAt
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
        var startedAt = Date()
    }

    /// Reads both players. YouTube Music only exposes a tree while it runs, and
    /// Spotify only while its process is up, so an idle panel does almost no work.
    private func probe() -> Probe {
        var result = Probe()
        result.trusted = YouTubeMusicAX.isTrusted
        // Both readers already answer nil when their app is not running, so a
        // single call each keeps the poll cheap.
        result.youtube = YouTubeMusicAX.shared.read()
        result.spotify = SpotifyController.shared.read()
        return result
    }

    private func apply(_ probe: Probe) {
        let youtubeRunning = YouTubeMusicAX.isAppRunning
        needsPermission = !probe.trusted && youtubeRunning

        // Chrome drops its tree for a moment when it rebuilds the page. One
        // empty read while the app is still up is not "nothing playing".
        if probe.youtube == nil, probe.spotify == nil, youtubeRunning, now.hasTrack,
           Date().timeIntervalSince(lastGoodRead) < 4 {
            return
        }
        if probe.youtube != nil || probe.spotify != nil { lastGoodRead = Date() }

        let youtube = probe.youtube
        let spotify = probe.spotify

        // Whichever player is actually running the audio wins; a paused YouTube
        // Music still beats a paused Spotify because it is the panel's default.
        let source: MediaSource
        var track = NowPlaying()
        if let youtube, youtube.isPlaying {
            source = .youtubeMusic
            track.title = youtube.title
            track.artist = youtube.artist
            track.album = youtube.album
            track.duration = youtube.duration
            track.position = youtube.position
            track.isPlaying = true
        } else if let spotify, spotify.isPlaying {
            source = .spotify
            track.title = spotify.title
            track.artist = spotify.artist
            track.album = spotify.album
            track.duration = spotify.duration
            track.position = spotify.position
            track.isPlaying = true
        } else if let youtube {
            source = .youtubeMusic
            track.title = youtube.title
            track.artist = youtube.artist
            track.album = youtube.album
            track.duration = youtube.duration
            track.position = youtube.position
            track.isPlaying = false
        } else if let spotify {
            source = .spotify
            track.title = spotify.title
            track.artist = spotify.artist
            track.album = spotify.album
            track.duration = spotify.duration
            track.position = spotify.position
            track.isPlaying = false
        } else {
            source = .youtubeMusic
        }

        track.source = source
        // A poll that began before the last click (Chrome needs a beat to
        // update the button) would flip the icon back; keep the optimistic state.
        if track.hasTrack, track.title == now.title, track.source == now.source,
           probe.startedAt < commandAt.addingTimeInterval(0.8) {
            track.isPlaying = now.isPlaying
            track.position = livePosition()
        }
        if track.hasTrack {
            sampledAt = Date()
            elapsedAtSample = track.position
            rate = track.isPlaying ? 1 : 0
        } else {
            rate = 0
        }
        resolveArtwork(&track, spotify: source == .spotify ? spotify : nil)
        if !track.sameDisplay(as: now) { now = track }
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
            queue.async { [weak self] in
                let image = SpotifyController.shared.artwork(from: url)
                DispatchQueue.main.async {
                    guard let self, let image, self.artworkKey == key else { return }
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
        optimisticallyToggle()
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
        sampledAt = Date()
        elapsedAtSample = 0
        confirmSoon()
    }

    /// Swallows only a genuine double-fire of the same click.
    private func acceptCommand() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastCommand) > 0.25 else { return false }
        lastCommand = now
        commandAt = now
        return true
    }

    /// Flips the panel's own state the instant the button is pressed.
    private func optimisticallyToggle() {
        let position = livePosition()
        now.isPlaying.toggle()
        sampledAt = Date()
        elapsedAtSample = position
        rate = now.isPlaying ? 1 : 0
    }

    /// Polls quickly for a couple of seconds so the new state or track lands fast.
    private func confirmSoon() {
        fastUntil = Date().addingTimeInterval(2.5)
        if active {
            pollSoon(after: 0.4)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.refresh() }
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
