import SwiftUI

struct SettingsView: View {
    @Environment(AuthManager.self) var authManager
    @Environment(GamesViewModel.self) var viewModel
    @Environment(SunshineHostStore.self) var sunshineHostStore
    @Environment(XCloudAuthManager.self) var xcloudAuth
    @Environment(XCloudLibraryStore.self) var xcloudLibrary

    @State private var showZonePicker = false
    @State private var showSunshinePairing = false
    @State private var showServiceSignIn = false
    @State private var sunshinePairingPIN = "0000"

    var body: some View {
        @Bindable var vm = viewModel
        @Bindable var sunshine = sunshineHostStore

        NavigationStack {
            Form {
                Section {
                    TextField("Host name", text: $sunshine.name)
                        .textInputAutocapitalization(.words)

                    TextField("Address", text: $sunshine.address)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    TextField("Wake-on-LAN MAC address", text: $sunshine.macAddress)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    LabeledContent("HTTP Port") {
                        HStack(spacing: 16) {
                            Button {
                                sunshine.httpPort = max(1, sunshine.httpPort - 1)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)

                            Text(String(sunshine.httpPort))
                                .monospacedDigit()
                                .frame(minWidth: 72)
                                .padding(.horizontal, 24)

                            Button {
                                sunshine.httpPort = min(65_535, sunshine.httpPort + 1)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    LabeledContent("HTTPS Port") {
                        HStack(spacing: 16) {
                            Button {
                                sunshine.httpsPort = max(1, sunshine.httpsPort - 1)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)

                            Text(sunshine.portText)
                                .monospacedDigit()
                                .frame(minWidth: 72)
                                .padding(.horizontal, 24)

                            Button {
                                sunshine.httpsPort = min(65_535, sunshine.httpsPort + 1)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    TextField("Web UI username", text: $sunshine.webUsername)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    SecureField("Web UI password", text: $sunshine.webPassword)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)

                    Picker("Streaming Resolution", selection: $vm.streamSettings.sunshineResolution) {
                        ForEach(commonResolutions, id: \.res) { item in
                            Text(sunshineResolutionLabel(item.res))
                                .tag(item.res)
                        }
                    }

                    LabeledContent("Status", value: sunshine.statusText)

                    Button {
                        sunshine.save()
                    } label: {
                        Label("Save Sunshine Host", systemImage: "checkmark.circle")
                    }
                    .disabled(sunshine.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button {
                        sunshine.save()
                        sunshinePairingPIN = sunshine.newPairingPIN()
                        showSunshinePairing = true
                    } label: {
                        Label(sunshine.isPaired ? "Pair Again" : "Pair Sunshine Host", systemImage: "link")
                    }
                    .disabled(!sunshine.isConfigured)

                    if sunshine.isConfigured {
                        Button(role: .destructive) {
                            sunshine.clear()
                        } label: {
                            Label("Remove Sunshine Host", systemImage: "trash")
                        }
                    }
                } header: {
                    Text("Sunshine")
                } footer: {
                    Text("Configure the Sunshine host and local Moonlight stream resolution. Web UI credentials let CloudNow read Sunshine artwork filenames for metadata matching.")
                }

                Section("Stream Quality") {
                    Picker("Resolution", selection: $vm.streamSettings.resolution) {
                        let common = commonResolutions.filter { viewModel.availableResolutions.contains($0.res) }
                        let other  = viewModel.availableResolutions.filter { res in !commonResolutions.map(\.res).contains(res) }
                        if !common.isEmpty {
                            Section("TV Standards") {
                                ForEach(common, id: \.res) { item in
                                    Label("\(item.res)  —  \(item.badge)", systemImage: item.symbol)
                                        .tag(item.res)
                                }
                            }
                        }
                        if !other.isEmpty {
                            Section("Other") {
                                ForEach(other, id: \.self) { res in
                                    Text(res).tag(res)
                                }
                            }
                        }
                    }

                    Picker("Frame Rate", selection: $vm.streamSettings.fps) {
                        ForEach(viewModel.availableFps, id: \.self) { fps in
                            Text("\(fps) fps").tag(fps)
                        }
                    }

                    Picker("Codec", selection: $vm.streamSettings.codec) {
                        ForEach(VideoCodec.allCases, id: \.self) { codec in
                            Text(codec.rawValue).tag(codec)
                        }
                    }

                    Picker(selection: $vm.streamSettings.colorQuality) {
                        ForEach(ColorQuality.allCases, id: \.self) { q in
                            Text(colorQualityLabel(q)).tag(q)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Color Quality")
                            if vm.streamSettings.colorQuality == .hdr10bit {
                                Text("⚠️ Experimental — GFN may downscale to ~540p when HDR is enabled.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else if vm.streamSettings.colorQuality == .sdr10bit {
                                Text("Recommended — full resolution with better color than 8-bit.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Standard dynamic range, widely compatible.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }

                    Picker("Keyboard Layout", selection: $vm.streamSettings.keyboardLayout) {
                        Text("English (US)").tag("en-US")
                        Text("English (UK)").tag("en-GB")
                        Text("French").tag("fr-FR")
                        Text("German").tag("de-DE")
                        Text("Spanish").tag("es-ES")
                        Text("Italian").tag("it-IT")
                        Text("Portuguese (Brazil)").tag("pt-BR")
                        Text("Hindi (India)").tag("hi-IN")
                        Text("Japanese").tag("ja-JP")
                        Text("Korean").tag("ko-KR")
                    }

                    Picker("Game Language", selection: $vm.streamSettings.gameLanguage) {
                        Text("English (US)").tag("en_US")
                        Text("English (UK)").tag("en_GB")
                        Text("French").tag("fr_FR")
                        Text("German").tag("de_DE")
                        Text("Spanish").tag("es_ES")
                        Text("Italian").tag("it_IT")
                        Text("Portuguese").tag("pt_BR")
                        Text("Hindi").tag("hi_IN")
                        Text("Japanese").tag("ja_JP")
                        Text("Korean").tag("ko_KR")
                    }

                    LabeledContent("Max Bitrate") {
                        HStack(spacing: 16) {
                            Button {
                                vm.streamSettings.isBitrateAuto = false
                                vm.streamSettings.maxBitrateKbps = max(15_000, vm.streamSettings.maxBitrateKbps - 5_000)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            Text("\(vm.streamSettings.maxBitrateKbps / 1000) Mbps")
                                .monospacedDigit()
                                .frame(minWidth: 72)
                                .padding(.horizontal, 24)
                            Button {
                                vm.streamSettings.isBitrateAuto = false
                                vm.streamSettings.maxBitrateKbps = min(100_000, vm.streamSettings.maxBitrateKbps + 5_000)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { vm.streamSettings.isBitrateAuto },
                        set: { enabled in
                            vm.streamSettings.isBitrateAuto = enabled
                            if enabled {
                                vm.streamSettings.applyRecommendedBitrate()
                            }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto Bitrate")
                            Text("Matches the cap to the selected resolution and frame rate.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }

                    Toggle(isOn: $vm.streamSettings.enableL4S) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Low Latency Mode (L4S)")
                            Text("Reduces buffering on networks with L4S support (requires a compatible router and ISP).")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section("Server Region") {
                    Button {
                        showZonePicker = true
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Preferred Zone")
                                Text("Auto routing picks the best balance of ping and queue depth. Tap to pin a specific region.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 8)
                            Spacer()
                            Text(zoneLabel(vm.streamSettings.preferredZoneUrl))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    if vm.streamSettings.preferredZoneUrl != nil {
                        Button("Clear — use automatic routing") {
                            vm.streamSettings.preferredZoneUrl = nil
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Microphone") {
                    Toggle(isOn: $vm.streamSettings.micEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Use Microphone")
                            Text("Enables voice chat via a connected Bluetooth headset or AirPods. Requires microphone permission.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                }

                Section("Controller") {
                    LabeledContent {
                        HStack(spacing: 16) {
                            Button {
                                vm.streamSettings.controllerDeadzone = max(0.05, vm.streamSettings.controllerDeadzone - 0.01)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            Text("\(Int(vm.streamSettings.controllerDeadzone * 100))%")
                                .monospacedDigit()
                                .frame(minWidth: 44)
                                .padding(.horizontal, 24)
                            Button {
                                vm.streamSettings.controllerDeadzone = min(0.30, vm.streamSettings.controllerDeadzone + 0.01)
                            } label: {
                                Image(systemName: "plus.circle")
                            }
                            .buttonStyle(.plain)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Deadzone")
                            Text("Increase if your controller drifts at rest. Default: 15%.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Picker(selection: $vm.streamSettings.overlayTriggerButton) {
                        ForEach(OverlayTriggerButton.allCases, id: \.self) { btn in
                            Text(btn.rawValue).tag(btn)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Overlay Button")
                            Text("Long-press this button during play to open the app overlay. Switch if it conflicts with an in-game action.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Toggle(isOn: $vm.streamSettings.enableSteamOverlayGesture) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Steam Overlay Gesture")
                            Text("Long-press the OTHER button (the one not set as Overlay Button) to send Shift+Tab and open the Steam overlay. e.g. with Overlay on Start, long-press View/Back.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Picker(selection: $vm.streamSettings.defaultRemoteInputMode) {
                        Text("Mouse").tag(RemoteInputMode.mouse)
                        Text("Gamepad").tag(RemoteInputMode.gamepad)
                        Text("DualSense").tag(RemoteInputMode.dualsense)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Default Input Mode")
                            Text("Siri Remote mode at stream start. Can be changed mid-session from the overlay menu.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    LabeledContent("Protocol", value: "XInput over GFN v2/v3")
                }

                Section("Account") {
                    if !authManager.isAuthenticated {
                        Button {
                            authManager.login()
                            showServiceSignIn = true
                        } label: {
                            Label("Connect GeForce NOW", systemImage: "bolt.fill")
                        }
                    }

                    if !xcloudAuth.isSignedIn {
                        Button {
                            xcloudAuth.signIn()
                            showServiceSignIn = true
                        } label: {
                            Label("Connect Xbox Cloud Gaming", systemImage: "xbox.logo")
                        }
                    }

                    if let user = authManager.session?.user {
                        LabeledContent("Name", value: user.displayName)
                        if let email = user.email {
                            LabeledContent("Email", value: email)
                        }
                        if let sub = viewModel.subscription {
                            LabeledContent("Membership", value: sub.membershipTier)
                            if !sub.isUnlimited, let remaining = sub.remainingMinutes {
                                let hours = remaining / 60
                                let mins  = remaining % 60
                                LabeledContent("Time Remaining", value: hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m")
                            }
                        } else {
                            LabeledContent("Membership", value: user.membershipTier)
                        }
                    }

                    if authManager.isAuthenticated {
                        Button(role: .destructive) {
                            authManager.logout()
                        } label: {
                            Label("Sign Out of NVIDIA", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }

                    if xcloudAuth.isSignedIn {
                        LabeledContent("Xbox Cloud Gaming", value: "Signed in")
                        Button(role: .destructive) {
                            xcloudAuth.signOut()
                            xcloudLibrary.clear()
                            viewModel.setXCloudGames([])
                        } label: {
                            Label("Sign Out of Microsoft", systemImage: "xbox.logo")
                        }
                    }
                }

                Section("Catalog Diagnostics") {
                    LabeledContent("Merged Catalog", value: "\(viewModel.mainGames.count)")
                    LabeledContent("Public Catalog", value: "\(viewModel.publicCatalogGames.count)")
                    LabeledContent("Sunshine Games", value: "\(viewModel.sunshineGames.count)")
                    LabeledContent("Missing Heroes", value: "\(viewModel.gamesMissingHeroCount)")
                    if viewModel.gamesWithCoverHeroFallbackCount > 0 {
                        LabeledContent("Cover Fallbacks", value: "\(viewModel.gamesWithCoverHeroFallbackCount)")
                    }
                    if viewModel.hiddenHeroCount > 0 {
                        LabeledContent("Hidden Heroes", value: "\(viewModel.hiddenHeroCount)")
                        Button {
                            viewModel.resetHiddenHeroes()
                        } label: {
                            Label("Reset Hidden Heroes", systemImage: "eye")
                        }
                    }
                    if viewModel.sunshineReviewNeededCount > 0 {
                        LabeledContent("Needs Review", value: "\(viewModel.sunshineReviewNeededCount)")
                    }
                    Button {
                        Task {
                            await viewModel.matchMissingMetadata(
                                authManager: authManager,
                                sunshineHostStore: sunshineHostStore
                            )
                        }
                    } label: {
                        if viewModel.isMatchingMetadata {
                            Label("Matching Missing Metadata", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("Match Missing Metadata", systemImage: "sparkles")
                        }
                    }
                    .disabled(viewModel.isMatchingMetadata || viewModel.isLoading)
                    if let status = viewModel.metadataMatchStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    let xboxCount = viewModel.catalogStoreCounts
                        .filter { $0.store == "XBOX" || $0.store == "MICROSOFT" }
                        .reduce(0) { $0 + $1.count }
                    if xboxCount > 0 {
                        LabeledContent("Xbox", value: "\(xboxCount)")
                    }
                    if !viewModel.doomCatalogMatches.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Doom Matches")
                            ForEach(viewModel.doomCatalogMatches.prefix(8)) { game in
                                Text("\(game.title) · \(storeList(game))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("")
            .sheet(isPresented: $showZonePicker) {
                ZonePickerView(selectedZoneUrl: $vm.streamSettings.preferredZoneUrl)
            }
            .sheet(isPresented: $showSunshinePairing) {
                SunshinePairingView(
                    pin: sunshinePairingPIN,
                    onStartOver: {
                        sunshineHostStore.clear()
                        showSunshinePairing = false
                    }
                )
                    .environment(sunshineHostStore)
            }
            .sheet(isPresented: $showServiceSignIn) {
                LoginView()
                    .environment(authManager)
                    .environment(xcloudAuth)
                    .onChange(of: authManager.isAuthenticated) { _, signedIn in
                        if signedIn { showServiceSignIn = false }
                    }
                    .onChange(of: xcloudAuth.isSignedIn) { _, signedIn in
                        if signedIn { showServiceSignIn = false }
                    }
            }
            .onChange(of: vm.streamSettings.resolution) { _, _ in
                applyAutoBitrateIfNeeded()
            }
            .onChange(of: vm.streamSettings.fps) { _, _ in
                applyAutoBitrateIfNeeded()
            }
        }
    }

    private func applyAutoBitrateIfNeeded() {
        guard viewModel.streamSettings.isBitrateAuto else { return }
        viewModel.streamSettings.applyRecommendedBitrate()
    }

    private func zoneLabel(_ url: String?) -> String {
        guard let url else { return "Automatic" }
        // Extract zone ID from URL like "https://np-aws-us-n-virginia-1.cloudmatchbeta.nvidiagrid.net/"
        let host = URL(string: url)?.host ?? url
        return host.components(separatedBy: ".").first?.uppercased() ?? url
    }

    private struct ResolutionEntry { let res: String; let badge: String; let symbol: String }
    private let commonResolutions: [ResolutionEntry] = [
        ResolutionEntry(res: "1280x720",  badge: "HD",      symbol: "tv"),
        ResolutionEntry(res: "1920x1080", badge: "Full HD", symbol: "tv"),
        ResolutionEntry(res: "2560x1440", badge: "2K",      symbol: "tv"),
        ResolutionEntry(res: "3840x2160", badge: "4K",      symbol: "4k.tv"),
    ]

    private func sunshineResolutionLabel(_ resolution: String) -> String {
        switch resolution {
        case "1280x720": return "720p — 1280x720"
        case "1920x1080": return "1080p — 1920x1080"
        case "2560x1440": return "1440p (2K) — 2560x1440"
        case "3840x2160": return "4K — 3840x2160"
        default: return resolution
        }
    }

    private func colorQualityLabel(_ q: ColorQuality) -> String {
        switch q {
        case .sdr8bit: return "SDR 8-bit"
        case .sdr10bit: return "SDR 10-bit"
        case .hdr10bit: return "HDR 10-bit"
        }
    }

    private func storeList(_ game: GameInfo) -> String {
        let stores = Set(game.variants.map { GameVariant(id: "", appStore: $0.appStore).storeName })
        return stores.sorted().joined(separator: ", ")
    }

}

// MARK: - Zone Picker

struct ZonePickerView: View {
    @Binding var selectedZoneUrl: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(GamesViewModel.self) private var viewModel

    @State private var zones: [GFNZone] = []
    @State private var isLoading = true
    @State private var error: String?

    private var groupedZones: [(region: String, label: String, flag: String, zones: [GFNZone])] {
        let grouped = Dictionary(grouping: zones) { $0.region }
        let order = ["US", "CA", "EU", "JP", "KR", "THAI", "MY"]
        let sortedRegions = order.filter { grouped[$0] != nil }
            + grouped.keys.filter { !order.contains($0) }.sorted()
        return sortedRegions.map { region in
            let meta = GFNZone.regionMeta[region] ?? (label: region, flag: "🌐")
            return (region, meta.label, meta.flag, grouped[region, default: []])
        }
    }

    private var autoZone: GFNZone? { zones.autoZone(isUnlimited: viewModel.subscription?.isUnlimited ?? false) }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading servers…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView("Can't Load Servers", systemImage: "wifi.exclamationmark",
                                          description: Text(error))
                } else {
                    List {
                        // Auto option
                        Section {
                            Button {
                                selectedZoneUrl = nil
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text("Automatic")
                                            .font(.body.weight(.semibold))
                                        if let best = autoZone {
                                            Text("Best: \(best.id) · Q\(best.queuePosition)\(best.pingMs.map { " · \($0) ms" } ?? "")")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedZoneUrl == nil {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.primary)
                                    }
                                }
                            }
                            .foregroundStyle(.primary)
                        }

                        // Zones by region
                        ForEach(groupedZones, id: \.region) { group in
                            Section("\(group.flag) \(group.label)") {
                                ForEach(group.zones) { zone in
                                    Button {
                                        selectedZoneUrl = zone.zoneUrl
                                        dismiss()
                                    } label: {
                                        HStack {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(zone.id)
                                                    .font(.body)
                                                HStack(spacing: 8) {
                                                    Label("Q \(zone.queuePosition)", systemImage: "person.3.fill")
                                                        .foregroundStyle(queueColor(zone.queuePosition))
                                                    if let ping = zone.pingMs {
                                                        Label("\(ping) ms", systemImage: "wifi")
                                                            .foregroundStyle(pingColor(ping))
                                                    } else if zone.isMeasuring {
                                                        Label("…", systemImage: "wifi")
                                                            .foregroundStyle(.secondary)
                                                    }
                                                }
                                                .font(.caption)
                                            }
                                            Spacer()
                                            if selectedZoneUrl == zone.zoneUrl {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .foregroundStyle(.primary)
                                            } else if autoZone?.id == zone.id {
                                                GlassBadge(text: "Best", systemImage: "sparkle", tone: .primary)
                                            }
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                }
                            }
                        }
                    }
                    .background(Color.appBackground)
                }
            }
            .background(Color.appBackground.ignoresSafeArea())
            .navigationTitle("Server Region")
            .task {
                await loadZones()
            }
        }
    }

    private func loadZones() async {
        isLoading = true
        error = nil
        do {
            zones = try await ZoneClient.shared.fetchZones()
            isLoading = false
            // Measure pings concurrently in batches of 6
            let batchSize = 6
            for start in stride(from: 0, to: zones.count, by: batchSize) {
                let end = min(start + batchSize, zones.count)
                let batch = zones[start..<end]
                await withTaskGroup(of: (String, Int?).self) { group in
                    for zone in batch {
                        group.addTask {
                            let ping = await ZoneClient.shared.measurePing(to: zone.zoneUrl)
                            return (zone.id, ping)
                        }
                    }
                    for await (id, ping) in group {
                        if let idx = zones.firstIndex(where: { $0.id == id }) {
                            zones[idx].pingMs = ping
                            zones[idx].isMeasuring = false
                        }
                    }
                }
            }
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    private func queueColor(_ q: Int) -> Color {
        if q <= 5 { return .green }
        if q <= 15 { return .yellow }
        if q <= 30 { return .orange }
        return .red
    }

    private func pingColor(_ ms: Int) -> Color {
        if ms < 30  { return .green }
        if ms < 80  { return .yellow }
        if ms < 150 { return .orange }
        return .red
    }
}

// MARK: - Sunshine Pairing

private enum SunshinePairingPhase: Equatable {
    case checking
    case waitingForApproval(SunshineServerInfo)
    case pairing(SunshineServerInfo)
    case paired(SunshineServerInfo)
    case failed(String)
}

private struct SunshinePairingOutcome: Sendable {
    let alreadyPaired: Bool
    let serverCertificateDER: Data?
    let hostName: String?
    let uniqueId: String?
    let httpsPort: Int?
}

struct SunshinePairingView: View {
    let pin: String
    var onStartOver: (() -> Void)? = nil

    @Environment(SunshineHostStore.self) private var sunshineHostStore
    @Environment(GamesViewModel.self) private var viewModel
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    @State private var phase: SunshinePairingPhase = .checking

    private let client = SunshineClient()

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 18) {
                ScrollView {
                    VStack(spacing: 22) {
                        Image(systemName: phaseIcon)
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(phaseTint)

                        VStack(spacing: 8) {
                            Text(phaseTitle)
                                .font(.title.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .minimumScaleFactor(0.72)
                                .multilineTextAlignment(.center)

                            Text(phaseSubtitle)
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .minimumScaleFactor(0.75)
                                .frame(maxWidth: 760)
                        }

                        if phase == .checking {
                            ProgressView()
                                .scaleEffect(1.1)
                                .tint(.primary)
                                .padding(.vertical, 30)
                        } else if showsPIN {
                            HStack(spacing: 12) {
                                ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                                    Text(String(digit))
                                        .font(.system(size: 48, weight: .bold, design: .rounded))
                                        .monospacedDigit()
                                        .frame(width: 70, height: 82)
                                        .background(
                                            RoundedRectangle(cornerRadius: 14)
                                                .fill(.ultraThinMaterial)
                                                .overlay(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(0.08)))
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 14)
                                                .strokeBorder(.white.opacity(0.22), lineWidth: 1)
                                        }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        if showsSteps {
                            VStack(alignment: .leading, spacing: 10) {
                                pairingStep("Add this PIN to your Sunshine host.")
                                pairingStep("Approve CloudNow when Sunshine asks to pair a Moonlight client.")
                                pairingStep("Keep this screen open while Sunshine approves the client.")
                            }
                            .frame(maxWidth: 760, alignment: .leading)
                        }

                    }
                }
                .scrollIndicators(.hidden)
            }
            .padding(48)
        }
        .task {
            await beginPairing()
        }
        .onExitCommand {
            exitPairing()
        }
    }

    private var phaseTitle: String {
        switch phase {
        case .checking:
            return "Checking Sunshine"
        case .waitingForApproval:
            return "Approve This PIN"
        case .pairing:
            return "Waiting for Sunshine"
        case .paired:
            return "Sunshine Paired"
        case .failed:
            return "Could Not Reach Sunshine"
        }
    }

    private var phaseSubtitle: String {
        switch phase {
        case .checking:
            return hostSubtitle
        case .waitingForApproval(let info):
            let name = info.hostName ?? sunshineHostStore.host?.name ?? "Sunshine"
            return "\(name) responded. Approve CloudNow in Sunshine."
        case .pairing(let info):
            let name = info.hostName ?? sunshineHostStore.host?.name ?? "Sunshine"
            return "Keep this open while \(name) approves the Moonlight client."
        case .paired(let info):
            let name = info.hostName ?? sunshineHostStore.host?.name ?? "Sunshine"
            return "\(name) reports this client is paired."
        case .failed(let message):
            return message
        }
    }

    private var phaseIcon: String {
        switch phase {
        case .checking:
            return "network"
        case .waitingForApproval:
            return "link.badge.plus"
        case .pairing:
            return "link.badge.plus"
        case .paired:
            return "checkmark.seal.fill"
        case .failed:
            return "wifi.exclamationmark"
        }
    }

    private var phaseTint: Color {
        switch phase {
        case .checking, .waitingForApproval, .pairing:
            return .primary
        case .paired:
            return .green
        case .failed:
            return .orange
        }
    }

    private var showsPIN: Bool {
        if case .waitingForApproval = phase { return true }
        if case .pairing = phase { return true }
        return false
    }

    private var showsSteps: Bool {
        if case .waitingForApproval = phase { return true }
        if case .pairing = phase { return true }
        return false
    }

    private var hostSubtitle: String {
        guard let host = sunshineHostStore.host else {
            return "Enter a Sunshine host address first."
        }
        return "\(host.name) · \(host.address):\(host.httpPort)"
    }

    private func exitPairing() {
        if case .paired = phase {
            dismiss()
            return
        }
        if let onStartOver {
            onStartOver()
        } else {
            sunshineHostStore.markPairingNeeded()
            dismiss()
        }
    }

    private func beginPairing() async {
        guard let host = sunshineHostStore.host else {
            phase = .failed("Enter a Sunshine host address first.")
            return
        }

        phase = .checking
        do {
            let info = try await client.fetchServerInfo(host: host)
            if info.isPaired {
                sunshineHostStore.completePairing(uniqueId: info.uniqueId, serverCertificateDER: nil, httpsPort: info.httpsPort, hostName: info.hostName, macAddress: info.macAddress)
                phase = .paired(info)
            } else {
                sunshineHostStore.markPairingNeeded()
                phase = .waitingForApproval(info)
                phase = .pairing(info)
                let outcome = try await pair(host: host, pin: pin)
                sunshineHostStore.completePairing(
                    uniqueId: outcome.uniqueId ?? info.uniqueId,
                    serverCertificateDER: outcome.serverCertificateDER,
                    httpsPort: outcome.httpsPort ?? info.httpsPort,
                    hostName: outcome.hostName ?? info.hostName,
                    macAddress: info.macAddress
                )
                let pairedInfo = SunshineServerInfo(
                    statusCode: 200,
                    statusMessage: outcome.alreadyPaired ? "Already paired" : "Paired",
                    hostName: outcome.hostName ?? info.hostName,
                    uniqueId: outcome.uniqueId ?? info.uniqueId,
                    appVersion: info.appVersion,
                    state: info.state,
                    currentGame: info.currentGame,
                    localIp: info.localIp,
                    macAddress: info.macAddress,
                    httpsPort: outcome.httpsPort ?? info.httpsPort,
                    pairStatus: 1,
                    serverCodecModeSupport: info.serverCodecModeSupport
                )
                phase = .paired(pairedInfo)
                Task {
                    await viewModel.load(authManager: authManager, sunshineHostStore: sunshineHostStore, force: true)
                }
            }
        } catch {
            sunshineHostStore.markPairingNeeded()
            phase = .failed(error.localizedDescription)
        }
    }

    private func pair(host: SunshineHost, pin: String) async throws -> SunshinePairingOutcome {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let pairer = CNMoonlightPairer(
                    address: host.address,
                    httpPort: host.httpPort,
                    httpsPort: host.httpsPort,
                    deviceName: "CloudNow tvOS"
                )
                do {
                    let result = try pairer.pair(withPIN: pin)
                    continuation.resume(returning: SunshinePairingOutcome(
                        alreadyPaired: result.alreadyPaired,
                        serverCertificateDER: result.serverCertificateDER,
                        hostName: result.hostName,
                        uniqueId: result.uniqueId,
                        httpsPort: result.httpsPort > 0 ? result.httpsPort : nil
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func pairingStep(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
}
