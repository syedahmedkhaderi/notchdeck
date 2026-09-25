import SwiftUI

/// The root only observes panel state and preferences; each widget observes its
/// own service, so a media or stats tick re-renders one column, not the panel.
struct PanelRootView: View {
    @ObservedObject var state: PanelState
    @ObservedObject var prefs: Preferences
    let stats: StatsModel
    let calendar: CalendarService
    let camera: CameraService
    let media: MediaService
    let brightness: BrightnessService
    let order: WidgetOrder
    var onRefresh: () -> Void
    var onQuit: () -> Void
    var onArrange: () -> Void

    private var ear: CGFloat { state.expanded ? Theme.earRadius : 0 }
    private var shapeSize: CGSize {
        state.expanded
            ? CGSize(width: state.panelWidth + ear * 2, height: state.headerHeight + Theme.contentHeight)
            : state.notchSize
    }

    var body: some View {
        ZStack(alignment: .top) {
            PanelShape(
                bottomRadius: state.expanded ? Theme.panelCornerRadius : Theme.collapsedCornerRadius,
                ear: ear
            )
            .fill(Theme.panelBackground)
            .frame(width: shapeSize.width, height: shapeSize.height)
            .shadow(color: .black.opacity(state.expanded ? 0.45 : 0), radius: 14, y: 6)

            if state.expanded {
                content
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        .environment(\.deckAccent, prefs.accent.color)
    }

    private var content: some View {
        VStack(spacing: 0) {
            PanelHeader(
                prefs: prefs,
                arranging: state.arranging,
                notchWidth: state.notchSize.width,
                height: state.headerHeight,
                onRefresh: onRefresh,
                onArrange: onArrange,
                onQuit: onQuit
            )
            if state.arranging {
                SettingsView(order: order, prefs: prefs, onDone: onArrange)
            } else {
                HomeTab(
                    stats: stats,
                    media: media,
                    calendar: calendar,
                    camera: camera,
                    brightness: brightness,
                    order: order,
                    prefs: prefs
                )
            }
        }
        .frame(width: state.panelWidth, height: state.headerHeight + Theme.contentHeight, alignment: .top)
        .clipShape(PanelShape(bottomRadius: Theme.panelCornerRadius))
    }
}
