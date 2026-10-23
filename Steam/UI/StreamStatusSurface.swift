import SwiftUI

enum StreamStatusTone {
    case loading
    case waiting
    case attention
    case warning
    case error
}

struct StreamStatusSurface: View {
    let game: GameInfo
    let title: String
    let message: String?
    var tone: StreamStatusTone = .loading
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var cancelAction: (() -> Void)? = nil
    @FocusState private var isActionFocused: Bool

    var body: some View {
        ZStack {
            StreamStartupBackground(game: game)

            VStack(spacing: 28) {
                Image("SteamMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 460, height: 276)
                    .accessibilityLabel("Steam")

                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 760)

                if let message, !message.isEmpty {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.48))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 760)
                }

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.36))
                        .multilineTextAlignment(.center)
                        .padding(.top, 16)
                }

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 220))
                        .focused($isActionFocused)
                        .defaultFocus($isActionFocused, true)
                        .padding(.top, 4)
                }
            }
            .padding(80)
        }
        .onAppear {
            guard actionTitle != nil else { return }
            DispatchQueue.main.async {
                isActionFocused = true
            }
        }
        .onChange(of: actionTitle) { _, newValue in
            guard newValue != nil else { return }
            DispatchQueue.main.async {
                isActionFocused = true
            }
        }
        .task(id: actionTitle) {
            guard let action else { return }
            await LaunchScreenControllerInput.monitor(
                onConfirm: action,
                onCancel: cancelAction ?? action
            )
        }
    }

}
