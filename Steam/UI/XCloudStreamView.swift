import LiveKitWebRTC
import SwiftUI

struct XCloudStreamView: View {
    let game: XCloudGame
    let controllerDeadzone: Double
    let onDismiss: () -> Void
    @Environment(XCloudAuthManager.self) private var auth
    @State private var controller = XCloudStreamController()
    @State private var showExit = false
    @State private var isClosing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch controller.state {
            case .idle:
                launchStatusSurface(
                    title: "Starting Xbox Cloud Gaming…",
                    message: nil,
                    tone: .loading,
                    actionTitle: "Cancel Stream"
                )
            case .connecting(let status):
                launchStatusSurface(
                    title: "Connecting stream…",
                    message: status,
                    tone: .loading,
                    actionTitle: "Cancel Stream"
                )
            case .streaming:
                XCloudVideoSurface(track: controller.videoTrack).ignoresSafeArea()
            case .failed(let message):
                launchStatusSurface(
                    title: "Xbox stream failed",
                    message: message,
                    tone: .error,
                    actionTitle: "Back to Xbox Games"
                )
            }
        }
        .task { await controller.connect(game: game, auth: auth, controllerDeadzone: controllerDeadzone) }
        .onAppear {
            controller.exitComboHandler = {
                close()
            }
        }
        .task {
            await ControllerExitGesture.monitorStartSelectHold {
                close()
            }
        }
        .onDisappear { controller.disconnect() }
        .confirmationDialog("Leave Xbox Cloud Gaming?", isPresented: $showExit) {
            Button("End Stream", role: .destructive) { close() }
            Button("Keep Playing", role: .cancel) {}
        }
        .onExitCommand {
            if controller.state == .streaming { showExit = true } else { close() }
        }
        .preventsTVOSScreenSaverDuringStream()
    }

    private func launchStatusSurface(
        title: String,
        message: String?,
        tone: StreamStatusTone,
        actionTitle: String
    ) -> some View {
        StreamStatusSurface(
            game: game.gameInfo,
            title: title,
            message: message,
            tone: tone,
            actionTitle: actionTitle,
            action: close,
            cancelAction: close
        )
    }

    private func close() {
        guard !isClosing else { return }
        isClosing = true
        controller.disconnect()
        onDismiss()
    }
}

private struct XCloudVideoSurface: UIViewControllerRepresentable {
    let track: LKRTCVideoTrack?
    func makeUIViewController(context: Context) -> StreamingViewController { StreamingViewController() }
    func updateUIViewController(_ controller: StreamingViewController, context: Context) {
        controller.videoSurface.videoTrack = track
    }
}
