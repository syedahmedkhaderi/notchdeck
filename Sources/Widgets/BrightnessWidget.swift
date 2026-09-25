import AppKit
import SwiftUI

/// External monitor brightness as slim vertical bars. The built-in panel keeps
/// its own control, so it never appears here.
struct BrightnessWidget: View {
    @ObservedObject var brightness: BrightnessService
    @Environment(\.deckAccent) private var accent

    private var external: [DisplayInfo] {
        Array(brightness.displays.filter { !$0.isBuiltin }.prefix(2))
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "sun.max.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .help("Display brightness")

            if external.isEmpty {
                Spacer(minLength: 0)
                Image(systemName: "display")
                    .font(.system(size: 16, weight: .light))
                    .foregroundStyle(Theme.textTertiary)
                    .help("No external monitor")
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 8) {
                    ForEach(external) { bar($0) }
                }
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func bar(_ display: DisplayInfo) -> some View {
        VStack(spacing: 5) {
            SliderView(
                level: display.level ?? 0,
                enabled: display.controllable,
                fill: NSColor(accent)
            ) { brightness.setLevel($0, for: display) }
            .frame(width: 22)
            .frame(maxHeight: .infinity)
            .help(display.controllable
                  ? "\(display.name) — drag or scroll"
                  : "\(display.name) does not answer DDC")

            Text(display.level.map { "\(Int(($0 * 100).rounded()))" } ?? "—")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(display.controllable ? Theme.textPrimary : Theme.textTertiary)
                .monospacedDigit()
        }
    }
}

/// Vertical brightness bar drawn in AppKit so dragging and scrolling stay
/// smooth without re-rendering SwiftUI on every step.
struct SliderView: NSViewRepresentable {
    var level: Double
    var enabled: Bool
    var fill: NSColor
    var onChange: (Double) -> Void

    func makeNSView(context: Context) -> Slider {
        let view = Slider()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: Slider, context: Context) {
        if !view.dragging { view.level = level }
        view.enabled = enabled
        view.fill = fill
        view.onChange = onChange
    }

    final class Slider: NSView {
        var level: Double = 0 { didSet { if level != oldValue { needsDisplay = true } } }
        var enabled = true { didSet { if enabled != oldValue { needsDisplay = true } } }
        var fill: NSColor = .systemGreen { didSet { if fill != oldValue { needsDisplay = true } } }
        var onChange: ((Double) -> Void)?
        private(set) var dragging = false

        private static let sun = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let track = bounds
            guard track.width > 1, track.height > 1 else { return }
            let radius = min(track.width / 2, 9)
            let clip = NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius)
            NSColor(white: 1, alpha: 0.10).setFill()
            clip.fill()

            // Flipped, so the fill grows up from the bottom edge.
            NSGraphicsContext.saveGraphicsState()
            clip.addClip()
            let height = track.height * min(max(level, 0), 1)
            (enabled ? fill : NSColor(white: 1, alpha: 0.2)).setFill()
            NSRect(x: track.minX, y: track.maxY - height, width: track.width, height: height).fill()
            NSGraphicsContext.restoreGraphicsState()

            // Sun at the foot of the bar, dark over the fill so it stays legible.
            if let sun = Self.sun {
                let size = sun.size
                let rect = NSRect(x: track.midX - size.width / 2, y: track.maxY - size.height - 6,
                                  width: size.width, height: size.height)
                let tinted = NSImage(size: size, flipped: false) { r in
                    sun.draw(in: r)
                    NSColor(white: 0, alpha: 0.55).set()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: rect)
            }
        }

        override func mouseDown(with event: NSEvent) { dragging = true; update(with: event) }
        override func mouseDragged(with event: NSEvent) { update(with: event) }
        override func mouseUp(with event: NSEvent) { dragging = false }

        override func scrollWheel(with event: NSEvent) {
            guard enabled else { return }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 220 : event.scrollingDeltaY / 24
            guard delta != 0 else { return }
            set(min(max(level + delta, 0), 1))
        }

        private func update(with event: NSEvent) {
            guard enabled, bounds.height > 0 else { return }
            let point = convert(event.locationInWindow, from: nil)
            set(min(max(1 - point.y / bounds.height, 0), 1))
        }

        private func set(_ value: Double) {
            guard abs(value - level) > 0.0005 else { return }
            level = value
            onChange?(value)
        }
    }
}
