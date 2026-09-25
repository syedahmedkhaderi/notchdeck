import SwiftUI

/// Compact player: artwork and track on top, scrubber, then transport.
struct NowPlayingWidget: View {
    @ObservedObject var media: MediaService
    @ObservedObject var prefs: Preferences
    @Environment(\.deckAccent) private var accent

    private var now: NowPlaying { media.now }
    private var tint: Color {
        if prefs.artworkTint, let t = now.tint { return Color(nsColor: t) }
        return accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                artwork
                trackInfo
            }
            ScrubberView(media: media, tint: tint)
                .padding(.top, 12)
            transport
                .padding(.top, 6)
        }
        .padding(.horizontal, Theme.gutter + 2)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var artwork: some View {
        Button(action: media.playPause) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.fill)
                if let image = now.artwork {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: now.artwork == nil ? .clear : tint.opacity(0.35), radius: 10, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(now.hasTrack ? "\(now.title) — \(now.sourceName)" : "Open YouTube Music and play")
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: now.source == .spotify ? "waveform" : "play.rectangle.fill")
                    .font(.system(size: 8, weight: .semibold))
                Text(now.sourceName.uppercased())
                    .font(.system(size: 8.5, weight: .semibold))
                    .tracking(0.5)
                if now.isPlaying {
                    Circle().fill(tint).frame(width: 4, height: 4).padding(.leading, 2)
                }
            }
            .foregroundStyle(Theme.textTertiary)
            .padding(.bottom, 1)

            Text(now.hasTrack ? now.title : "Nothing playing")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(now.hasTrack ? Theme.textPrimary : Theme.textSecondary)
            Text(subtitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var transport: some View {
        HStack(spacing: 22) {
            control("backward.fill", action: media.previous)
            Button(action: media.playPause) {
                Image(systemName: now.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .offset(x: now.isPlaying ? 0 : 1)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Theme.textPrimary))
                    .contentShape(Circle())
            }
            .buttonStyle(PressStyle())
            control("forward.fill", action: media.next)
        }
        .frame(maxWidth: .infinity)
    }

    private var subtitle: String {
        if !now.hasTrack {
            if media.launching { return "Starting YouTube Music…" }
            if media.needsPermission { return "Needs Accessibility access" }
            return "Tap the cover to play"
        }
        return now.artist.isEmpty ? now.album : now.artist
    }

    private func control(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary.opacity(0.9))
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(HoverButtonStyle())
    }
}

/// The playhead is the only thing that changes every second, so it gets its
/// own timeline and the rest of the player stays static between track changes.
private struct ScrubberView: View {
    @ObservedObject var media: MediaService
    var tint: Color

    var body: some View {
        if media.now.isPlaying {
            TimelineView(.periodic(from: .now, by: 1)) { _ in bar }
        } else {
            bar
        }
    }

    private var bar: some View {
        let now = media.now
        let position = now.hasTrack ? media.livePosition() : 0
        let progress = now.duration > 0 ? min(max(position / now.duration, 0), 1) : 0
        return HStack(spacing: 8) {
            Text(Self.time(position))
                .frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.trackBackground)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, geo.size.width * progress))
                }
            }
            .frame(height: 4)
            Text(Self.time(now.duration))
                .frame(width: 30, alignment: .trailing)
        }
        .font(.system(size: 9.5, weight: .medium, design: .rounded))
        .foregroundStyle(Theme.textTertiary)
        .monospacedDigit()
        .frame(height: 12)
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
