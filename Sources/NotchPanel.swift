import AppKit

/// Borderless, non-activating panel that floats above the menu bar. It takes key
/// focus only when a control inside it needs it.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Invisible strip over the camera housing. Its tracking area opens the panel,
/// so a closed notch needs no global mouse monitor and the app stays asleep
/// while the pointer moves anywhere else.
final class NotchTriggerView: NSView {
    var onEnter: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
