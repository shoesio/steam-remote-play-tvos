import SwiftUI

struct UnifiedSettingsView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(XCloudAuthManager.self) private var xcloudAuth
    @Environment(XCloudLibraryStore.self) private var xcloudLibrary
    @Environment(SunshineHostStore.self) private var sunshine
    @Environment(HomeKitPowerOutletStore.self) private var homeKitPowerOutletStore
    @Environment(GamesViewModel.self) private var viewModel

    @State private var showSignIn = false
    @State private var showZonePicker = false
    @State private var showSunshinePairing = false
    @State private var showSunshineSetup = false
    @State private var showSteamGridDBConnection = false
    @State private var sunshinePIN = "0000"

    var body: some View {
        @Bindable var vm = viewModel
        @Bindable var sunshineStore = sunshine
        @Bindable var outletStore = homeKitPowerOutletStore

        NavigationStack {
            Form {
                    Section {
                        LabeledContent("Stick Deadzone") {
                            HStack(spacing: 16) {
                                Button { vm.streamSettings.controllerDeadzone = max(0.05, vm.streamSettings.controllerDeadzone - 0.01) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.plain)
                                Text("\(Int(vm.streamSettings.controllerDeadzone * 100))%").monospacedDigit().frame(minWidth: 52)
                                Button { vm.streamSettings.controllerDeadzone = min(0.30, vm.streamSettings.controllerDeadzone + 0.01) } label: { Image(systemName: "plus.circle") }
                                    .buttonStyle(.plain)
                            }
                        }
                    } header: {
                        Text("Controller")
                    } footer: {
                        Text("Applied consistently to GFN, Sunshine, and X-box controller input.")
                    }

                Section {
                    if viewModel.isSteamGridDBConnected {
                        LabeledContent("SteamGridDB", value: "Connected")
                        Button {
                            Task {
                                await viewModel.matchMissingMetadata(
                                    authManager: authManager,
                                    sunshineHostStore: sunshine
                                )
                            }
                        } label: {
                            if viewModel.isMatchingMetadata {
                                Label("Matching Missing Artwork", systemImage: "arrow.triangle.2.circlepath")
                            } else {
                                Label("Match Missing Artwork", systemImage: "photo.stack")
                            }
                        }
                        .disabled(viewModel.isMatchingMetadata || viewModel.isLoading)
                        Button(role: .destructive) { viewModel.disconnectSteamGridDB() } label: {
                            Label("Disconnect SteamGridDB", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } else {
                        Button { showSteamGridDBConnection = true } label: {
                            Label("Connect SteamGridDB", systemImage: "photo.stack")
                        }
                    }
                    if let status = viewModel.metadataMatchStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    ProviderSettingsHeader(title: "Artwork", systemImage: "photo.on.rectangle.angled", tint: .blue)
                }

                    Section {
                        if sunshine.isPaired {
                            LabeledContent("Status", value: "Connected")
                            LabeledContent("Host", value: sunshine.host.map { "\($0.name) · \($0.address)" } ?? sunshine.statusText)
                            TextField("Wake-on-LAN MAC address", text: $sunshineStore.macAddress)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .onSubmit { sunshineStore.save() }
                            if outletStore.hasStarted || outletStore.hasSelectedOutlet {
                                Picker("Apple Home Power Outlet", selection: $outletStore.selectedOutletID) {
                                    Text("None").tag("")
                                    if !outletStore.selectedOutletID.isEmpty,
                                       !outletStore.outlets.contains(where: { $0.id == outletStore.selectedOutletID }) {
                                        Text(outletStore.isReady ? "Saved outlet unavailable" : "Loading saved outlet…")
                                            .tag(outletStore.selectedOutletID)
                                    }
                                    ForEach(outletStore.outlets) { outlet in
                                        Text(outlet.displayName).tag(outlet.id)
                                    }
                                }
                            }
                            Button {
                                Task { await outletStore.refresh() }
                            } label: {
                                Label(
                                    outletStore.hasStarted ? "Refresh Apple Home Outlets" : "Connect Apple Home",
                                    systemImage: "house.fill"
                                )
                            }
                            if let outlet = outletStore.selectedOutlet {
                                LabeledContent("Outlet Status") {
                                    Text(outlet.isReachable ? (outlet.isOn == true ? "On" : "Off") : "Unreachable")
                                }
                            }
                            Picker("Resolution", selection: $vm.streamSettings.sunshineResolution) {
                                ForEach(resolutions, id: \.self) { Text(resolutionLabel($0)).tag($0) }
                            }
                            Picker("Frame Rate", selection: $vm.streamSettings.sunshineFPS) {
                                Text("30 fps").tag(30); Text("60 fps").tag(60)
                            }
                            Picker("Codec", selection: $vm.streamSettings.sunshineCodec) {
                                ForEach(SunshineVideoCodec.allCases, id: \.self) { codec in
                                    Text(sunshineCodecLabel(codec)).tag(codec)
                                }
                            }
                            Toggle("Automatic Bitrate", isOn: $vm.streamSettings.sunshineIsBitrateAuto)
                            if !vm.streamSettings.sunshineIsBitrateAuto {
                                LabeledContent("Maximum Bitrate") {
                                    HStack(spacing: 16) {
                                        Button {
                                            let step = StreamSettings.sunshineBitrateStepKbps(codec: vm.streamSettings.sunshineCodec)
                                            vm.streamSettings.sunshineMaxBitrateKbps = max(5_000, vm.streamSettings.sunshineMaxBitrateKbps - step)
                                        } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                                        Text("\(vm.streamSettings.sunshineMaxBitrateKbps / 1000) Mbps").monospacedDigit().frame(minWidth: 80)
                                        Button {
                                            let codec = vm.streamSettings.sunshineCodec
                                            let step = StreamSettings.sunshineBitrateStepKbps(codec: codec)
                                            vm.streamSettings.sunshineMaxBitrateKbps = min(
                                                StreamSettings.maximumSunshineBitrateKbps(codec: codec),
                                                vm.streamSettings.sunshineMaxBitrateKbps + step
                                            )
                                        } label: { Image(systemName: "plus.circle") }.buttonStyle(.plain)
                                    }
                                }
                            }
                            Toggle(isOn: $vm.streamSettings.sunshineOptimizeGameSettings) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Optimize Game Settings")
                                    Text("Lets Sunshine apply host-side game optimizations before streaming.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            Toggle(isOn: $vm.streamSettings.sunshineSmoothFramePacing) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Frame Pacing: Smooth")
                                    Text("Uses timed video samples for smoother Moonlight playback.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            Toggle(isOn: $vm.streamSettings.sunshineExitGameOnStreamClose) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Exit Game on Stream Close")
                                    Text("Sends Sunshine a quit request when the Moonlight stream closes.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            LabeledContent("Games", value: "\(viewModel.sunshineGames.count)")
                            if let lastSync = viewModel.lastSunshineSync {
                                LabeledContent("Last Sync") {
                                    Text(lastSync, style: .relative)
                                }
                            }
                            Button {
                                Task { await viewModel.syncSunshine(hostStore: sunshine, force: true) }
                            } label: {
                                if viewModel.isSunshineSyncing {
                                    Label("Syncing Games…", systemImage: "arrow.triangle.2.circlepath")
                                } else {
                                    Label("Force Sync Games", systemImage: "arrow.clockwise")
                                }
                            }
                            .disabled(viewModel.isSunshineSyncing || viewModel.isLoading)
                            if let sunshineError = viewModel.sunshineError {
                                Text(sunshineError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            Button("Pair Again") { beginSunshinePairing() }
                            Button(role: .destructive) { sunshineStore.clear() } label: {
                                Label("Disconnect Sunshine", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } else {
                            LabeledContent("Status", value: sunshine.isConfigured ? "Configured" : "Not configured")
                            if sunshine.isConfigured {
                                LabeledContent("Host", value: sunshine.host.map { "\($0.name) · \($0.address)" } ?? sunshine.statusText)
                            }
                            Button {
                                if sunshine.isConfigured { beginSunshinePairing() }
                                else { showSunshineSetup = true }
                            } label: {
                                Label(sunshine.isConfigured ? "Pair Sunshine" : "Set Up Sunshine", systemImage: "sun.max.fill")
                            }
                            if sunshine.isConfigured {
                                Button {
                                    showSunshineSetup = true
                                } label: {
                                    Label("Edit Sunshine Details", systemImage: "square.and.pencil")
                                }
                                Button(role: .destructive) {
                                    sunshineStore.clear()
                                } label: {
                                    Label("Clear Sunshine Setup", systemImage: "trash")
                                }
                            }
                        }
                    } header: {
                        ProviderSettingsHeader(title: "Sunshine", systemImage: "sun.max.fill", tint: .orange)
                    }

                    Section {
                        if authManager.isAuthenticated, let user = authManager.session?.user {
                            LabeledContent("Account", value: user.displayName)
                            LabeledContent("Plan", value: viewModel.subscription?.membershipTier ?? user.membershipTier)
                            Picker("Resolution", selection: $vm.streamSettings.resolution) {
                                ForEach(viewModel.availableResolutions, id: \.self) { Text(resolutionLabel($0)).tag($0) }
                            }
                            Picker("Frame Rate", selection: $vm.streamSettings.fps) {
                                ForEach(viewModel.availableFps, id: \.self) { Text("\($0) fps").tag($0) }
                            }
                            Picker("Codec", selection: $vm.streamSettings.codec) {
                                ForEach(VideoCodec.allCases, id: \.self) { Text(codecLabel($0)).tag($0) }
                            }
                            bitrateControl(settings: $vm.streamSettings)
                            Button { showZonePicker = true } label: {
                                LabeledContent("Server Region", value: zoneLabel(vm.streamSettings.preferredZoneUrl))
                            }
                            Toggle("Microphone / Voice Chat", isOn: $vm.streamSettings.micEnabled)
                            Picker("CloudNow Overlay Button", selection: $vm.streamSettings.overlayTriggerButton) {
                                ForEach(OverlayTriggerButton.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                            }
                            Button(role: .destructive) { authManager.logout() } label: {
                                Label("Disconnect GFN", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } else {
                            LabeledContent("Status", value: "Not connected")
                            Button {
                                authManager.login()
                                showSignIn = true
                            } label: {
                                Label("Set Up GeForce NOW", systemImage: "bolt.fill")
                            }
                        }
                    } header: {
                        ProviderSettingsHeader(title: "GFN", systemImage: "bolt.fill", tint: .green)
                    }

                    Section {
                        if xcloudAuth.isSignedIn {
                            LabeledContent("Status", value: "Connected")
                            LabeledContent("Playable Library", value: "\(xcloudLibrary.games.count) games")
                            LabeledContent("Resolution", value: "1080p")
                            LabeledContent("Frame Rate", value: "60 fps")
                            LabeledContent("Codec", value: "H.264")
                            LabeledContent("Bitrate", value: "25 Mbps")
                            Button(role: .destructive) {
                                xcloudAuth.signOut()
                                xcloudLibrary.clear()
                                viewModel.setXCloudGames([])
                            } label: {
                                Label("Disconnect X-box", systemImage: "rectangle.portrait.and.arrow.right")
                            }
                        } else {
                            LabeledContent("Status", value: "Not connected")
                            Button {
                                xcloudAuth.signIn()
                                showSignIn = true
                            } label: {
                                Label("Set Up X-box Cloud Gaming", systemImage: "xbox.logo")
                            }
                        }
                    } header: {
                        ProviderSettingsHeader(title: "X-box", systemImage: "xbox.logo", tint: .green)
                    }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("")
            .sheet(isPresented: $showSignIn) {
                LoginView()
                    .environment(authManager)
                    .environment(xcloudAuth)
                    .onChange(of: authManager.isAuthenticated) { _, value in if value { showSignIn = false } }
                    .onChange(of: xcloudAuth.isSignedIn) { _, value in if value { showSignIn = false } }
            }
            .sheet(isPresented: $showZonePicker) {
                ZonePickerView(selectedZoneUrl: $vm.streamSettings.preferredZoneUrl)
                    .environment(viewModel)
            }
            .sheet(isPresented: $showSunshinePairing) {
                SunshinePairingView(
                    pin: sunshinePIN,
                    onStartOver: {
                        sunshine.clear()
                        showSunshinePairing = false
                        showSunshineSetup = true
                    }
                )
                .environment(sunshine)
            }
            .sheet(isPresented: $showSunshineSetup) {
                SunshineConnectionView().environment(sunshine)
            }
            .sheet(isPresented: $showSteamGridDBConnection) {
                SteamGridDBConnectionView().environment(viewModel)
            }
            .onChange(of: vm.streamSettings.resolution) { _, _ in applyAutoBitrate() }
            .onChange(of: vm.streamSettings.fps) { _, _ in applyAutoBitrate() }
            .onChange(of: vm.streamSettings.sunshineResolution) { _, _ in applySunshineAutoBitrate() }
            .onChange(of: vm.streamSettings.sunshineFPS) { _, _ in applySunshineAutoBitrate() }
            .onChange(of: vm.streamSettings.sunshineCodec) { _, _ in applySunshineAutoBitrate() }
            .onChange(of: vm.streamSettings.sunshineIsBitrateAuto) { _, enabled in
                if enabled { applySunshineAutoBitrate() }
            }
            .task {
                guard outletStore.hasSelectedOutlet else { return }
                await outletStore.refresh()
            }
        }
    }

    @ViewBuilder
    private func bitrateControl(settings: Binding<StreamSettings>) -> some View {
        Toggle("Automatic Bitrate", isOn: settings.isBitrateAuto)
        if !settings.wrappedValue.isBitrateAuto {
            LabeledContent("Maximum Bitrate") {
                HStack(spacing: 16) {
                    Button { settings.wrappedValue.maxBitrateKbps -= 5_000 } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    Text("\(settings.wrappedValue.maxBitrateKbps / 1000) Mbps").monospacedDigit().frame(minWidth: 80)
                    Button { settings.wrappedValue.maxBitrateKbps += 5_000 } label: { Image(systemName: "plus.circle") }.buttonStyle(.plain)
                }
            }
        }
    }

    private func beginSunshinePairing() {
        sunshine.save()
        sunshinePIN = sunshine.newPairingPIN()
        showSunshinePairing = true
    }

    private func applyAutoBitrate() {
        guard viewModel.streamSettings.isBitrateAuto else { return }
        viewModel.streamSettings.applyRecommendedBitrate()
    }

    private func applySunshineAutoBitrate() {
        guard viewModel.streamSettings.sunshineIsBitrateAuto else { return }
        viewModel.streamSettings.sunshineMaxBitrateKbps = StreamSettings.recommendedSunshineBitrateKbps(
            resolution: viewModel.streamSettings.sunshineResolution,
            fps: viewModel.streamSettings.sunshineFPS,
            codec: viewModel.streamSettings.sunshineCodec
        )
    }

    private let resolutions = ["1280x720", "1920x1080", "2560x1440", "3840x2160"]
    private func resolutionLabel(_ value: String) -> String {
        switch value {
        case "1280x720": return "720p"
        case "1920x1080": return "1080p"
        case "2560x1440": return "1440p"
        case "3840x2160": return "4K"
        default: return value
        }
    }
    private func codecLabel(_ codec: VideoCodec) -> String {
        switch codec { case .h264: return "H.264"; case .h265: return "H.265"; case .av1: return "AV1" }
    }
    private func sunshineCodecLabel(_ codec: SunshineVideoCodec) -> String {
        switch codec {
        case .automatic: return "Automatic"
        case .h264: return "H.264"
        case .pyroWaveExperimental: return "PyroWave Experimental"
        }
    }
    private func zoneLabel(_ value: String?) -> String {
        guard let value else { return "Automatic" }
        return URL(string: value)?.host?.components(separatedBy: ".").first?.uppercased() ?? "Custom"
    }
}

private struct SteamGridDBConnectionView: View {
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            VStack(spacing: 12) {
                ProviderQRCodeSignInView(
                    title: "Connect SteamGridDB",
                    systemImage: "photo.stack.fill",
                    tint: .blue,
                    qrValue: SteamGridDBService.apiKeyURL,
                    instruction: "Scan to sign in and create an API key, then paste it below using the Apple TV keyboard.",
                    onCancel: { dismiss() }
                )
                HStack(spacing: 18) {
                    SecureField("SteamGridDB API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .frame(maxWidth: 620)
                    Button {
                        connect()
                    } label: {
                        if isConnecting { ProgressView() } else { Text("Connect") }
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 160))
                    .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isConnecting)
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).multilineTextAlignment(.center)
                }
            }
            .padding(.bottom, 36)
        }
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil
        Task {
            do {
                try await viewModel.connectSteamGridDB(apiKey: apiKey)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isConnecting = false
            }
        }
    }
}

private struct SunshineConnectionView: View {
    @Environment(SunshineHostStore.self) private var sunshine
    @Environment(\.dismiss) private var dismiss
    @State private var pairingPIN: String?

    var body: some View {
        @Bindable var store = sunshine

        ZStack {
            Color.appBackground.ignoresSafeArea()
            if let pairingPIN {
                SunshinePairingView(
                    pin: pairingPIN,
                    onStartOver: {
                        sunshine.clear()
                        self.pairingPIN = nil
                    }
                )
                    .environment(sunshine)
            } else {
                VStack(spacing: 34) {
                    ProviderSettingsHeader(title: "Connect Sunshine", systemImage: "sun.max.fill", tint: .orange)
                        .font(.title2)
                    Text("Enter the address of the PC running Sunshine.")
                        .foregroundStyle(.secondary)
                    VStack(spacing: 18) {
                        TextField("PC address or hostname", text: $store.address)
                            .textInputAutocapitalization(.never)
                            .disableAutocorrection(true)
                        TextField("Display name", text: $store.name)
                    }
                    .frame(maxWidth: 660)
                    Button("Save and Pair") {
                        store.save()
                        pairingPIN = store.newPairingPIN()
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 190))
                    .disabled(store.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(70)
            }
        }
        .onExitCommand {
            if pairingPIN == nil {
                dismiss()
            }
        }
        .onChange(of: sunshine.isPaired) { _, paired in
            if paired { dismiss() }
        }
    }
}
