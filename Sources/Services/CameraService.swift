import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Mirrored camera preview for the right-hand column.
///
/// The capture session starts only when the user clicks Mirror and is torn down
/// again as soon as the mirror is dismissed, so the camera light is never on by
/// accident and macOS never keeps the device warm behind the user's back.
final class CameraService: ObservableObject {
    /// True between clicking Mirror and dismissing the preview.
    @Published private(set) var active = false
    @Published private(set) var denied = false
    @Published private(set) var failed = false
    /// Flips once the session is really pushing frames, which is what the view
    /// waits for instead of showing a black rectangle.
    @Published private(set) var running = false
    /// Replaced on every start so the view always previews a fresh graph.
    @Published private(set) var session = AVCaptureSession()

    private var visible = false
    private var starting = false
    /// Every session transition goes through here in order, so a stop can never
    /// land in the middle of a start.
    private let sessionQueue = DispatchQueue(label: "notchdeck.camera.session")

    /// The preview is on screen only when the user asked for it.
    var isShowing: Bool { active }

    // MARK: User actions

    func start() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .denied || status == .restricted {
            openPrivacySettings()
            return
        }
        denied = false
        failed = false
        active = true
        apply()
    }

    func stop() {
        active = false
        shutDown()
    }

    /// The panel opened or closed. Nothing is captured while it is closed, and
    /// closing it also drops the mirror, so opening the notch never switches the
    /// camera on by itself.
    func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        if !value { active = false }
        apply()
    }

    func stopAll() {
        visible = false
        active = false
        shutDown()
    }

    // MARK: Session

    private func apply() {
        guard active, visible else {
            shutDown()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            denied = false
            begin()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if granted { self.begin() } else { self.denied = true; self.active = false }
                }
            }
        default:
            denied = true
            active = false
        }
    }

    /// Builds the capture graph from scratch on every start.
    ///
    /// Restarting a session that had been stopped leaves it reporting
    /// `isRunning` with a live, enabled preview connection and yet no frames
    /// arrive, which is what kept the mirror black the second time it was
    /// switched on. A brand-new graph behaves exactly like a first start, and the
    /// old one is dropped on the floor by the stop path.
    private func begin() {
        guard !starting else { return }

        let graph = AVCaptureSession()
        graph.sessionPreset = .high

        let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
        guard let device, let input = try? AVCaptureDeviceInput(device: device),
              graph.canAddInput(input) else {
            failed = true
            active = false
            return
        }
        graph.addInput(input)
        session = graph

        starting = true
        sessionQueue.async { [weak self] in
            guard let self else { return }
            Debug.log("cam start graph running=\(graph.isRunning)")
            if !graph.isRunning { graph.startRunning() }
            let isRunning = graph.isRunning
            Debug.log("cam started isRunning=\(isRunning)")
            DispatchQueue.main.async {
                self.starting = false
                self.running = isRunning
                self.failed = !isRunning
            }
        }
    }

    private func shutDown() {
        running = false
        let graph = session
        sessionQueue.async {
            Debug.log("cam stop graph isRunning=\(graph.isRunning)")
            guard graph.isRunning else { return }
            graph.stopRunning()
        }
    }

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!
        NSWorkspace.shared.open(url)
    }
}

/// Hosts an `AVCaptureVideoPreviewLayer` that always fills its bounds.
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(session: session)
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.attach(session)
    }

    final class PreviewView: NSView {
        private let previewLayer: AVCaptureVideoPreviewLayer

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
            previewLayer.videoGravity = .resizeAspectFill
            // The layer lives *inside* the view rather than being the view's own
            // backing layer: AppKit then keeps the geometry in sync on every
            // resize, which is what used to leave the preview black.
            layer?.addSublayer(previewLayer)
            Debug.log("cam preview init layer=\(layer != nil) superlayer=\(previewLayer.superlayer != nil)")
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func attach(_ session: AVCaptureSession) {
            if previewLayer.session !== session { previewLayer.session = session }
            syncFrame()
        }

        override func layout() {
            super.layout()
            syncFrame()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncFrame()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            syncFrame()
        }

        /// The video is centred on the column: `resizeAspectFill` scales the
        /// frame up and crops the overflow evenly on both sides, so the layer
        /// has to sit exactly on the view's bounds for that to stay true.
        private func syncFrame() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            if let layer, previewLayer.superlayer !== layer { layer.addSublayer(previewLayer) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if previewLayer.frame != bounds { previewLayer.frame = bounds }
            previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }
    }
}
