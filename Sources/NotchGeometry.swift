import AppKit

/// Screen-space geometry for the notch and the expanded panel.
struct NotchGeometry {
    static let fallbackNotchSize = CGSize(width: 200, height: 32)

    let screen: NSScreen
    let notchSize: CGSize
    /// Width of the open panel's body, excluding the flared ears.
    let panelWidth: CGFloat

    init(screen: NSScreen, contentWidth: CGFloat) {
        self.screen = screen
        if let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea,
           right.minX > left.maxX {
            self.notchSize = CGSize(width: right.minX - left.maxX, height: left.height)
        } else {
            self.notchSize = NotchGeometry.fallbackNotchSize
        }
        // The header needs room for the clock on the left and the buttons on the
        // right, either side of the camera housing.
        let minimum = notchSize.width + 300
        self.panelWidth = min(max(contentWidth, minimum), screen.frame.width - 40)
    }

    /// The header sits behind the camera housing, so it is never shorter than it.
    var headerHeight: CGFloat { max(Theme.minHeaderHeight, notchSize.height) }
    var panelHeight: CGFloat { headerHeight + Theme.contentHeight }
    var panelSize: CGSize { CGSize(width: panelWidth, height: panelHeight) }

    var notchRect: CGRect {
        let f = screen.frame
        return CGRect(x: f.midX - notchSize.width / 2, y: f.maxY - notchSize.height,
                      width: notchSize.width, height: notchSize.height)
    }

    /// The panel plus a transparent margin for the ears and the animation.
    var windowFrame: CGRect {
        let f = screen.frame
        let w = panelWidth + Theme.windowMargin * 2
        let h = panelHeight + Theme.windowMargin
        return CGRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
    }

    var panelRect: CGRect {
        let f = screen.frame
        return CGRect(x: f.midX - panelWidth / 2, y: f.maxY - panelHeight,
                      width: panelWidth, height: panelHeight)
    }

    /// Hit area that keeps the panel open.
    var hoverRect: CGRect { panelRect.insetBy(dx: -6, dy: -6) }

    /// Hit area that opens the panel.
    var openRect: CGRect { notchRect.insetBy(dx: -10, dy: -4) }
}
