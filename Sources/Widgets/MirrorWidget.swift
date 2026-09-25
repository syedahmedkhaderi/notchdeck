import SwiftUI

/// Camera mirror: a tile that turns into a mirrored preview when tapped.
struct MirrorWidget: View {
    @ObservedObject var camera: CameraService

    var body: some View {
        Group {
            if camera.isShowing { preview } else { startButton }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 14)
    }

    private var preview: some View {
        ZStack(alignment: .topTrailing) {
            CameraPreview(session: camera.session, cornerRadius: 16)
                .scaleEffect(x: -1, y: 1)

            if !camera.running {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(camera.failed ? "Camera unavailable" : "Starting…")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button(action: camera.stop) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(.black.opacity(0.5)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(7)
            .help("Stop mirroring")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.fill)
    }

    private var startButton: some View {
        Button(action: camera.start) {
            VStack(spacing: 8) {
                Image(systemName: camera.denied ? "video.slash.fill" : "person.crop.square")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Theme.textSecondary)
                Text(camera.denied ? "No access" : "Mirror")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.fill)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(camera.denied ? "Camera access is off — open System Settings › Privacy" : "Start mirroring")
    }
}
