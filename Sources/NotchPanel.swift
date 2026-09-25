import AppKit

/// Borderless, non-activating panel that floats above the menu bar. It takes key
/// focus only when a control inside it needs it.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
