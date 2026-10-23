import SwiftUI

struct LoginView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(XCloudAuthManager.self) var xcloudAuth
    @AppStorage("app.localProviderSetup") private var localProviderSetup = false

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if xcloudAuth.phase != .signedOut && xcloudAuth.phase != .signedIn {
                xboxSignInView
            } else {
                switch authManager.loginPhase {
                case .idle:
                    loginPrompt
                case .showingPIN(let code, let url, let urlComplete):
                    pinView(code: code, url: url, urlComplete: urlComplete)
                case .exchangingTokens:
                    exchangingView
                case .failed(let message):
                    failedView(message: message)
                }
            }
        }
    }

    // MARK: Login Prompt

    private var loginPrompt: some View {
        VStack(spacing: 48) {
            VStack(spacing: 12) {
                Image("StreamLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 210, height: 96)
                Text("Stream")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text("Your cloud and local games on Apple TV")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 18) {
                ProviderConnectionButton(
                    title: "Sunshine",
                    subtitle: "Stream from your local PC",
                    systemImage: "sun.max.fill",
                    tint: .orange
                ) { localProviderSetup = true }

                ProviderConnectionButton(
                    title: "GFN",
                    subtitle: "Sign in with NVIDIA",
                    systemImage: "bolt.fill",
                    tint: .green
                ) { authManager.login() }

                ProviderConnectionButton(
                    title: "X-box",
                    subtitle: "Sign in with Microsoft",
                    systemImage: "xbox.logo",
                    tint: .green
                ) { xcloudAuth.signIn() }
            }
        }
        .padding(80)
    }

    @ViewBuilder
    private var xboxSignInView: some View {
        switch xcloudAuth.phase {
        case .requestingCode, .exchangingTokens:
            ProviderConnectionProgressView(title: "Connecting X-box…", systemImage: "xbox.logo", tint: .green)
        case .waitingForUser(let code):
            ProviderQRCodeSignInView(
                title: "Connect X-box",
                systemImage: "xbox.logo",
                tint: .green,
                qrValue: code.directURL ?? code.verificationURL,
                instruction: "Scan with your phone, then complete Microsoft sign-in.",
                code: code.code,
                status: "Waiting for sign in…",
                onCancel: { xcloudAuth.cancelSignIn() }
            )
        case .failed(let message):
            connectionFailedView(title: "X-box Connection Failed", message: message, systemImage: "xbox.logo") {
                xcloudAuth.signIn()
            } onBack: {
                xcloudAuth.cancelSignIn()
            }
        default:
            EmptyView()
        }
    }

    // MARK: PIN Display

    private func pinView(code: String, url: String, urlComplete: String) -> some View {
        ProviderQRCodeSignInView(
            title: "Connect GFN",
            systemImage: "bolt.fill",
            tint: .green,
            qrValue: urlComplete,
            instruction: "Scan with your phone, then complete NVIDIA sign-in at \(url).",
            code: code,
            status: "Waiting for sign in…",
            onCancel: { authManager.cancelLogin() }
        )
    }

    // MARK: Exchanging Tokens

    private var exchangingView: some View {
        ProviderConnectionProgressView(title: "Connecting GFN…", systemImage: "bolt.fill", tint: .green)
    }

    // MARK: Failed

    private func failedView(message: String) -> some View {
        connectionFailedView(title: "GFN Connection Failed", message: message, systemImage: "bolt.fill") {
            authManager.login()
        } onBack: {
            authManager.cancelLogin()
        }
    }

    private func connectionFailedView(
        title: String,
        message: String,
        systemImage: String,
        onRetry: @escaping () -> Void,
        onBack: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 32) {
            Image(systemName: systemImage)
                .font(.system(size: 60))
                .foregroundStyle(.red)
            Text(title)
                .font(.title.weight(.semibold))
                .foregroundStyle(.primary)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 24) {
                Button("Try Again") {
                    onRetry()
                }
                .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 150))
                Button("Back") { onBack() }
                    .buttonStyle(AppActionButtonStyle(tone: .secondary, minWidth: 130))
            }
        }
        .padding(80)
    }

    // MARK: Helpers

}
