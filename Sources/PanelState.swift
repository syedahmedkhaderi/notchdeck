import Foundation

final class PanelState: ObservableObject {
    @Published var expanded = false
    /// True while the settings sheet is showing inside the panel.
    @Published var arranging = false
    @Published var panelWidth: CGFloat = 600
    @Published var headerHeight: CGFloat = Theme.minHeaderHeight
    @Published var notchSize = NotchGeometry.fallbackNotchSize
}
