import AppKit
import SwiftUI

/// Lets the very first click land on a control even though the panel never
/// becomes the active app.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel!
    private var geometry: NotchGeometry!

    private let state = PanelState()
    private let prefs = Preferences()
    private let stats = StatsModel()
    private let calendar = CalendarService()
    private let camera = CameraService()
    private let media = MediaService()
    private let brightness = BrightnessService()
    private let order = WidgetOrder()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var safetyTimer: Timer?
    private var collapseWork: DispatchWorkItem?
    private var screenObserver: NSObjectProtocol?
    private var sampling = false

    /// `--preview` keeps the panel open so the layout can be inspected without a
    /// cursor; `--settings` additionally opens the settings sheet.
    private let previewMode = CommandLine.arguments.contains("--preview")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        guard let screen = NSScreen.screens.first else { return }
        buildWindow(for: screen)
        installPointerMonitors()
        calendar.start()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, let screen = NSScreen.screens.first else { return }
            self.buildWindow(for: screen)
        }

        if previewMode {
            panel.ignoresMouseEvents = false
            panel.makeKeyAndOrderFront(nil)
            state.expanded = true
            if CommandLine.arguments.contains("--settings") {
                state.arranging = true
                layout()
            }
            setSampling(active: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stats.stop()
        media.stop()
        calendar.stop()
        brightness.stop()
        camera.stopAll()
    }

    // MARK: Window

    private func buildWindow(for screen: NSScreen) {
        let root = PanelRootView(
            state: state,
            prefs: prefs,
            stats: stats,
            calendar: calendar,
            camera: camera,
            media: media,
            brightness: brightness,
            order: order,
            onRefresh: { [weak self] in self?.refresh() },
            onQuit: { NSApp.terminate(nil) },
            onArrange: { [weak self] in self?.toggleArrange() }
        )
        let hosting = PanelHostingView(rootView: root)

        if panel == nil {
            let newPanel = NotchPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.level = NSWindow.Level(rawValue: 27)
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = false
            newPanel.isMovable = false
            newPanel.hidesOnDeactivate = false
            newPanel.ignoresMouseEvents = !previewMode
            newPanel.becomesKeyOnlyIfNeeded = true
            newPanel.animationBehavior = .none
            newPanel.isReleasedWhenClosed = false
            panel = newPanel
        }
        panel.contentView = hosting
        layout(screen: screen)
        panel.orderFrontRegardless()
    }

    /// Sizes the window to the visible widgets. Geometry, hit areas and the
    /// window frame are always updated together so the hover logic never
    /// works from a stale rectangle.
    private func layout(screen: NSScreen? = nil) {
        guard let screen = screen ?? geometry?.screen else { return }
        var width = Theme.contentWidth(of: order.visible)
        if state.arranging {
            // Frozen while the sheet is open, so toggling a widget never
            // resizes the panel under the pointer.
            width = max(state.panelWidth, Theme.settingsWidth)
        }
        geometry = NotchGeometry(screen: screen, contentWidth: width)
        state.panelWidth = geometry.panelWidth
        state.headerHeight = geometry.headerHeight
        state.notchSize = geometry.notchSize
        panel.setFrame(geometry.windowFrame, display: true)
    }

    /// Only the services behind visible widgets run, and only while the panel
    /// is open, so an idle notch costs nothing.
    private func setSampling(active: Bool) {
        sampling = active
        let visible = Set(order.visible)
        let on = { (id: WidgetID) in active && visible.contains(id) }

        stats.configure(memory: on(.memory), battery: on(.battery))
        if on(.player) { media.start() } else { media.stop() }
        if on(.brightness) { brightness.start() } else { brightness.stop() }
        calendar.setActive(on(.calendar))
        camera.setVisible(on(.mirror))
        setSafetyTimer(active: active)
    }

    private func toggleArrange() {
        state.arranging.toggle()
        layout()
        if state.arranging {
            panel.makeKeyAndOrderFront(nil)
        } else if sampling {
            setSampling(active: true)
        }
    }

    private func refresh() {
        stats.refresh()
        media.refresh()
        calendar.reload()
    }

    // MARK: Pointer handling

    private func installPointerMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown]
        ) { [weak self] event in
            guard let self, !self.previewMode else { return }
            if event.type == .leftMouseDown, self.state.expanded {
                self.collapse()
                return
            }
            self.evaluatePointer()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.evaluatePointer()
            return event
        }
    }

    /// Safety net for the rare case where the pointer moves without a delivered
    /// event. It only runs while the panel is open.
    private func setSafetyTimer(active: Bool) {
        safetyTimer?.invalidate()
        safetyTimer = nil
        guard active, !previewMode else { return }
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in self?.evaluatePointer() }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        safetyTimer = timer
    }

    private func evaluatePointer() {
        guard !previewMode else { return }
        let location = NSEvent.mouseLocation
        if state.expanded {
            if geometry.hoverRect.contains(location) {
                collapseWork?.cancel()
                collapseWork = nil
            } else if collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.collapse() }
                collapseWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
            }
        } else if geometry.openRect.contains(location) {
            expand()
        }
    }

    private func expand() {
        collapseWork?.cancel()
        collapseWork = nil
        guard !state.expanded else { return }
        panel.ignoresMouseEvents = false
        setSampling(active: true)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { state.expanded = true }
    }

    private func collapse() {
        guard state.expanded else { return }
        collapseWork?.cancel()
        collapseWork = nil
        panel.ignoresMouseEvents = true
        setSampling(active: false)
        withAnimation(.easeIn(duration: 0.14)) { state.expanded = false }
        if state.arranging {
            state.arranging = false
            layout()
        }
    }
}
