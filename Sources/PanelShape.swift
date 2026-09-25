import SwiftUI

/// Panel silhouette: rounded bottom corners, and top corners that flare outward
/// into the menu bar by `ear`. The rect includes the ears, so the body is
/// `rect.width - 2 * ear` wide.
struct PanelShape: Shape {
    var bottomRadius: CGFloat
    var ear: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(bottomRadius, ear) }
        set { bottomRadius = newValue.first; ear = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let e = max(0, min(ear, rect.width / 4, rect.height / 2))
        let left = rect.minX + e
        let right = rect.maxX - e
        let r = max(0, min(bottomRadius, rect.height - e, (right - left) / 2))
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: right, y: rect.minY + e), control: CGPoint(x: right, y: rect.minY))
        p.addLine(to: CGPoint(x: right, y: rect.maxY - r))
        p.addQuadCurve(to: CGPoint(x: right - r, y: rect.maxY), control: CGPoint(x: right, y: rect.maxY))
        p.addLine(to: CGPoint(x: left + r, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: left, y: rect.maxY - r), control: CGPoint(x: left, y: rect.maxY))
        p.addLine(to: CGPoint(x: left, y: rect.minY + e))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY), control: CGPoint(x: left, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
