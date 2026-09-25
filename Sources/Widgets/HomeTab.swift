import SwiftUI

/// The home deck: the visible widgets in the user's order, separated by short
/// hairlines.
struct HomeTab: View {
    let stats: StatsModel
    let media: MediaService
    let calendar: CalendarService
    let camera: CameraService
    let brightness: BrightnessService
    @ObservedObject var order: WidgetOrder
    let prefs: Preferences

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(order.visible.enumerated()), id: \.element) { index, id in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.divider)
                        .frame(width: 1)
                        .padding(.vertical, 22)
                }
                widget(id)
                    .frame(width: Theme.width(for: id), height: Theme.contentHeight, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func widget(_ id: WidgetID) -> some View {
        switch id {
        case .player: NowPlayingWidget(media: media, prefs: prefs)
        case .calendar: CalendarWidget(calendar: calendar).standardPadding()
        case .memory: MemoryWidget(stats: stats).standardPadding()
        case .battery: SystemWidget(stats: stats).standardPadding()
        case .brightness: BrightnessWidget(brightness: brightness).standardPadding()
        case .mirror: MirrorWidget(camera: camera)
        }
    }
}

extension View {
    func standardPadding() -> some View {
        padding(.horizontal, Theme.gutter)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
