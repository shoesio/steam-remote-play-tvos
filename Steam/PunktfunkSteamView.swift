import AVFoundation
import GameController
import Observation
import PunktfunkKit
import SwiftUI

@MainActor
@Observable
final class PunktfunkSteamSession {
    static let shared = PunktfunkSteamSession()

    enum State {
        case idle
        case connecting
        case streaming
        case failed(String)
    }

    var state: State = .idle
    private(set) var connection: PunktfunkConnection?
    private var connectTask: Task<Void, Never>?

    private static let hostFingerprint = Data(hex: "97493a7fd86b3ba1dbcf4d97e53da3f32fa21a03f402422c45aa0f2f477b18e5")

    func start() {
        guard connectTask == nil, connection == nil else { return }
        state = .connecting
        let host = SteamTVSettings.hostAddress
        let port = SteamTVSettings.nativePort
        let mode = SteamTVSettings.nativeMode
        let bitrate = SteamTVSettings.nativeBitrateKbps
        connectTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let identity = try PunktfunkIdentityStore.shared.loadForPairing()
                let connection = try PunktfunkConnection(
                    host: host,
                    port: port,
                    width: mode.width,
                    height: mode.height,
                    refreshHz: mode.fps,
                    pinSHA256: Self.hostFingerprint,
                    identity: identity,
                    // This app represents the console itself, not a library game. Ask Punktfunk
                    // for Bazzite's managed Gamescope session directly; launching
                    // `steam:big-picture` would only run Steam's UI inside the active desktop.
                    compositor: .gamescope,
                    gamepad: .auto,
                    bitrateKbps: bitrate,
                    videoCaps: 0,
                    audioChannels: 2,
                    videoCodecs: PunktfunkConnection.codecPyroWave,
                    preferredCodec: PunktfunkConnection.codecPyroWave,
                    clientCaps: 0,
                    launchID: nil,
                    timeoutMs: 185_000
                )
                connection.setVideoDropped(false)
                connection.requestKeyframe()
                let mode = connection.currentMode()
                print("Steam Punktfunk session: \(mode.width)x\(mode.height)@\(mode.refreshHz), codec=\(connection.resolvedCodec), bitrate=\(connection.resolvedBitrateKbps / 1000) Mbps")
                await MainActor.run {
                    guard let self else { connection.close(); return }
                    self.connection = connection
                    self.connectTask = nil
                    self.state = .streaming
                }
            } catch {
                await MainActor.run {
                    self?.connectTask = nil
                    self?.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        connectTask?.cancel()
        connectTask = nil
        // Publish the intentional stop before closing transport so a resulting
        // read error cannot be mistaken for an unexpected stream loss.
        state = .idle
        connection?.close()
        connection = nil
    }

    /// tvOS does not preserve a usable Metal presentation surface while the app is in the
    /// background. Close the native connection without sending `disconnectQuit`: Punktfunk keeps
    /// the managed Gamescope display in its reconnect window, and a foreground `start()` attaches
    /// a fresh decoder/presenter to that same host session.
    func suspendForBackground() {
        stop()
    }

    /// Top Shelf's explicit host shutdown is a true end, not a temporary app/background drop.
    /// Tell Punktfunk to release the managed Gamescope session immediately before the legacy
    /// shutdown utility powers the machine off.
    func endForHostShutdown() {
        connectTask?.cancel()
        connectTask = nil
        connection?.disconnectQuit()
        connection?.close()
        connection = nil
        state = .idle
    }

    func retry() {
        stop()
        start()
    }
}

@MainActor
@Observable
private final class PunktfunkSteamDiagnostics {
    var resolution = "—"
    var refreshHz: UInt32 = 0
    var bitrateMbps: UInt32 = 0
    var receivedFrames: UInt64 = 0
    var presentedFrames: UInt64 = 0
    var transportDrops: UInt64 = 0
    var decodeErrors: UInt64 = 0
    var presentationErrors: UInt64 = 0
    var lastError = "None"

    @ObservationIgnored private var pendingReceived: UInt64 = 0
    @ObservationIgnored private var pendingPresented: UInt64 = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private weak var connection: PunktfunkConnection?

    func start(connection: PunktfunkConnection) {
        stop()
        self.connection = connection
        let mode = connection.currentMode()
        resolution = "\(mode.width) × \(mode.height)"
        refreshHz = mode.refreshHz
        bitrateMbps = connection.resolvedBitrateKbps / 1_000
        receivedFrames = 0
        presentedFrames = 0
        transportDrops = connection.framesDropped()
        decodeErrors = 0
        presentationErrors = 0
        lastError = "None"
        pendingReceived = 0
        pendingPresented = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        connection = nil
    }

    func noteReceived(_ count: UInt64) { pendingReceived += count }
    func notePresented() { pendingPresented += 1 }

    func noteDecodeError(_ error: String) {
        decodeErrors += 1
        lastError = error
    }

    func notePresentationError(_ error: String) {
        presentationErrors += 1
        lastError = error
    }

    func noteStreamError(_ error: String) { lastError = error }

    private func publish() {
        receivedFrames = pendingReceived
        presentedFrames = pendingPresented
        if let connection {
            transportDrops = connection.framesDropped()
            let mode = connection.currentMode()
            resolution = "\(mode.width) × \(mode.height)"
            refreshHz = mode.refreshHz
            bitrateMbps = connection.resolvedBitrateKbps / 1_000
        }
    }
}

struct PunktfunkSteamView: View {
    let onStreamEnded: () -> Void
    // The stream belongs to the app, not to one transient SwiftUI view. tvOS can remove and
    // recreate the root view around system overlays/settings; keeping this owner stable prevents
    // those transitions from closing a healthy Punktfunk connection and opening another session.
    @State private var session = PunktfunkSteamSession.shared
    @State private var diagnostics = PunktfunkSteamDiagnostics()
    @AppStorage(SteamTVSettings.Key.debugOverlay) private var showDebugOverlay = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            switch session.state {
            case .streaming:
                if let connection = session.connection {
                    PunktfunkSteamVideoSurface(
                        connection: connection,
                        onExit: {
                            guard case .streaming = session.state else { return }
                            onStreamEnded()
                        },
                        diagnostics: diagnostics
                    )
                    .ignoresSafeArea()
                    if showDebugOverlay {
                        PunktfunkDebugOverlay(diagnostics: diagnostics)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(42)
                            .allowsHitTesting(false)
                    }
                }
            case .failed(let message):
                statusView(title: "Steam could not start", detail: message, retry: true)
            case .connecting:
                statusView(
                    title: "Opening SteamOS…",
                    detail: "Connecting to the BC-250 at 4K 60 fps. If this is the first launch, approve Steam Punktfunk on the host.",
                    retry: false
                )
            case .idle:
                statusView(title: "Opening SteamOS…", detail: nil, retry: false)
            }
        }
        .task { session.start() }
    }

    @ViewBuilder
    private func statusView(title: String, detail: String?, retry: Bool) -> some View {
        VStack(spacing: 28) {
            Image("SteamMark")
                .resizable()
                .scaledToFit()
                .frame(width: 460, height: 276)
            Text(title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
            if let detail {
                Text(detail)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 900)
            }
            if retry {
                Button("Try Again") { session.retry() }
                    .buttonStyle(.borderedProminent)
            } else {
                ProgressView().controlSize(.large).tint(.white)
            }
        }
    }
}

private struct PunktfunkDebugOverlay: View {
    let diagnostics: PunktfunkSteamDiagnostics

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(diagnostics.resolution) @ \(diagnostics.refreshHz)  •  \(diagnostics.bitrateMbps) Mbps")
                .fontWeight(.bold)
            Text("Frames \(diagnostics.presentedFrames)/\(diagnostics.receivedFrames)  •  Drops \(diagnostics.transportDrops)  •  Errors \(diagnostics.decodeErrors + diagnostics.presentationErrors)")
            Text(diagnostics.lastError == "None" ? "PyroWave" : diagnostics.lastError)
                .foregroundStyle(diagnostics.lastError == "None" ? .white.opacity(0.7) : .orange)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 620, alignment: .leading)
        }
        .font(.system(size: 15, weight: .medium, design: .monospaced))
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.15))
        }
    }
}

private final class PunktfunkSteamEngine: @unchecked Sendable {
    private let connection: PunktfunkConnection
    private weak var videoView: CNMoonlightVideoView?
    private var decoder: CNMoonlightPyroWaveDecoder
    private var pump: Task<Void, Never>?
    private var audio: SessionAudio?
    @MainActor private var gamepad: GamepadCapture?
    @MainActor private var remoteNavigation: SteamRemoteNavigation?
    @MainActor private let diagnostics: PunktfunkSteamDiagnostics

    @MainActor
    init(
        connection: PunktfunkConnection, videoView: CNMoonlightVideoView,
        diagnostics: PunktfunkSteamDiagnostics
    ) {
        self.connection = connection
        self.videoView = videoView
        self.diagnostics = diagnostics
        let mode = connection.currentMode()
        decoder = CNMoonlightPyroWaveDecoder(width: Int32(mode.width), height: Int32(mode.height))
        videoView.configureVideoWidth(Int(mode.width), height: Int(mode.height))
        videoView.prepareForPyroWaveMetalRendering()
        videoView.suppressesSystemPresses = true
    }

    @MainActor
    func start(onExit: @escaping () -> Void) {
        diagnostics.start(connection: connection)
        let sessionAudio = SessionAudio(connection: connection)
        sessionAudio.start(speakerUID: "", micUID: "", micChannel: 0, micEnabled: false, echoCancel: false)
        audio = sessionAudio

        let capture = GamepadCapture(connection: connection, manager: .shared)
        capture.onDisconnectRequest = onExit
        capture.start()
        gamepad = capture

        if let videoView {
            let remote = SteamRemoteNavigation(connection: connection)
            remote.onDisconnectRequest = onExit
            remote.attach(to: videoView)
            remoteNavigation = remote
        }

        let connection = connection
        let exitHandler = onExit
        let weakView = WeakPunktfunkVideoView(videoView)
        let initialDecoder = decoder
        pump = Task.detached(priority: .userInitiated) {
            var activeDecoder = initialDecoder
            var decoderSize = (Int(connection.currentMode().width), Int(connection.currentMode().height))
            var receivedBatch: UInt64 = 0
            var emptyPolls = 0
            var hasReceivedFirstFrame = false
            while !Task.isCancelled {
                do {
                    guard let au = try autoreleasepool(invoking: {
                        try connection.nextAU(timeoutMs: 100)
                    }) else {
                        emptyPolls += 1
                        // A cold Gamescope takeover may need Punktfunk's capture-pipeline
                        // retries before the first frame exists. Once video has started,
                        // ten silent seconds still indicates a genuinely lost stream.
                        let emptyPollLimit = hasReceivedFirstFrame ? 100 : 600
                        if emptyPolls >= emptyPollLimit {
                            await MainActor.run {
                                self.diagnostics.noteStreamError("The host stopped sending video.")
                                exitHandler()
                            }
                            break
                        }
                        continue
                    }
                    emptyPolls = 0
                    hasReceivedFirstFrame = true
                    receivedBatch += 1
                    if receivedBatch == 30 {
                        await MainActor.run { self.diagnostics.noteReceived(receivedBatch) }
                        receivedBatch = 0
                    }
                    connection.noteFrameIndex(au.frameIndex)
                    let chunked = (au.flags & PunktfunkConnection.userFlagChunkAligned) != 0
                    if let size = punktfunkFrameSize(au.data, chunkAligned: chunked, windowSize: Int(connection.shardPayload)),
                       size != decoderSize {
                        decoderSize = size
                        activeDecoder = await MainActor.run {
                            weakView.value?.configureVideoWidth(size.0, height: size.1)
                            weakView.value?.prepareForPyroWaveMetalRendering()
                            return CNMoonlightPyroWaveDecoder(width: Int32(size.0), height: Int32(size.1))
                        }
                    }
                    autoreleasepool {
                        activeDecoder.submitPunktfunkAccessUnit(
                            au.data,
                            chunkAligned: chunked,
                            windowSize: UInt(connection.shardPayload),
                            frameIndex: au.frameIndex,
                            ptsNs: au.ptsNs
                        ) { frame, sample, error in
                            DispatchQueue.main.async {
                                guard let view = weakView.value else {
                                    frame?.markPresentationComplete(atTime: CACurrentMediaTime())
                                    return
                                }
                                if let frame {
                                    var displayError: NSString?
                                    if !view.display(frame, error: &displayError) {
                                        let message = "\(displayError ?? "unknown")"
                                        self.diagnostics.notePresentationError(message)
                                        print("Steam Punktfunk presentation failed: \(message)")
                                    } else {
                                        self.diagnostics.notePresented()
                                    }
                                } else if let sample {
                                    view.displayLayer.enqueue(sample)
                                    self.diagnostics.notePresented()
                                } else if let error {
                                    self.diagnostics.noteDecodeError(error)
                                    print("Steam Punktfunk decode failed: \(error)")
                                }
                            }
                        }
                    }
                } catch {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        if receivedBatch > 0 { self.diagnostics.noteReceived(receivedBatch) }
                        self.diagnostics.noteStreamError(error.localizedDescription)
                    }
                    print("Steam Punktfunk video ended: \(error)")
                    await MainActor.run { exitHandler() }
                    break
                }
            }
        }
    }

    @MainActor
    func stop() {
        pump?.cancel()
        pump = nil
        gamepad?.stop()
        gamepad = nil
        remoteNavigation?.stop()
        remoteNavigation = nil
        audio?.stop()
        audio = nil
        diagnostics.stop()
    }
}

@MainActor
private final class SteamRemoteNavigation {
    private let connection: PunktfunkConnection
    private weak var videoView: CNMoonlightVideoView?
    private var heldButtons: Set<UInt32> = []
    private var menuDownAt: Date?
    private let pad: UInt32 = 15
    var onDisconnectRequest: (() -> Void)?

    init(connection: PunktfunkConnection) {
        self.connection = connection
        connection.send(.gamepadArrival(pref: 1, pad: pad))
        connection.send(.gamepadAxis(GamepadWire.axisLSX, value: 0, pad: pad))
    }

    func attach(to view: CNMoonlightVideoView) {
        videoView = view
        view.remoteDirectionPressHandler = { [weak self] direction, pressed in
            self?.direction(direction, pressed: pressed)
        }
        view.remoteSelectPressHandler = { [weak self] pressed in
            self?.set(GamepadWire.a, down: pressed)
        }
        view.remoteBackPressHandler = { [weak self] pressed in
            self?.set(GamepadWire.b, down: pressed)
        }
        view.remoteMenuPressHandler = { [weak self] pressed in
            self?.menu(pressed: pressed)
        }
        DispatchQueue.main.async { view.becomeFirstResponder() }
    }

    func stop() {
        videoView?.remoteDirectionPressHandler = nil
        videoView?.remoteSelectPressHandler = nil
        videoView?.remoteBackPressHandler = nil
        videoView?.remoteMenuPressHandler = nil
        for button in heldButtons {
            connection.send(.gamepadButton(button, down: false, pad: pad))
        }
        heldButtons.removeAll()
        connection.send(.gamepadRemove(pad: pad))
    }

    private func direction(_ direction: Int, pressed: Bool) {
        let button: UInt32
        switch direction {
        case 1: button = GamepadWire.dpadUp
        case 2: button = GamepadWire.dpadDown
        case 3: button = GamepadWire.dpadLeft
        case 4: button = GamepadWire.dpadRight
        default: return
        }
        set(button, down: pressed)
    }

    private func menu(pressed: Bool) {
        if pressed {
            menuDownAt = Date()
            return
        }
        let heldFor = menuDownAt.map { Date().timeIntervalSince($0) } ?? 0
        menuDownAt = nil
        if heldFor >= 1.0 {
            onDisconnectRequest?()
        } else {
            set(GamepadWire.b, down: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                self?.set(GamepadWire.b, down: false)
            }
        }
    }

    private func set(_ button: UInt32, down: Bool) {
        guard down ? !heldButtons.contains(button) : heldButtons.contains(button) else { return }
        if down { heldButtons.insert(button) } else { heldButtons.remove(button) }
        connection.send(.gamepadButton(button, down: down, pad: pad))
    }
}

private final class PunktfunkSteamViewController: GCEventViewController {
    let videoView = CNMoonlightVideoView(frame: .zero)

    override func viewDidLoad() {
        super.viewDidLoad()
        // Match Punktfunk's official tvOS stream container: controller buttons belong to the
        // remote session, not UIKit. Without this, B/East is forwarded to the host and also
        // interpreted locally as Back, which suspends the stream.
        controllerUserInteractionEnabled = false
        view.backgroundColor = .black
        videoView.frame = view.bounds
        videoView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoView)
    }
}

private struct PunktfunkSteamVideoSurface: UIViewControllerRepresentable {
    let connection: PunktfunkConnection
    let onExit: () -> Void
    let diagnostics: PunktfunkSteamDiagnostics

    final class Coordinator {
        var engine: PunktfunkSteamEngine?
        deinit { Task { @MainActor [engine] in engine?.stop() } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> PunktfunkSteamViewController {
        let controller = PunktfunkSteamViewController()
        controller.loadViewIfNeeded()
        let engine = PunktfunkSteamEngine(
            connection: connection, videoView: controller.videoView, diagnostics: diagnostics
        )
        context.coordinator.engine = engine
        engine.start(onExit: onExit)
        return controller
    }

    func updateUIViewController(
        _ uiViewController: PunktfunkSteamViewController, context: Context
    ) {}

    static func dismantleUIViewController(
        _ uiViewController: PunktfunkSteamViewController, coordinator: Coordinator
    ) {
        coordinator.engine?.stop()
        coordinator.engine = nil
    }
}

private final class WeakPunktfunkVideoView: @unchecked Sendable {
    weak var value: CNMoonlightVideoView?
    init(_ value: CNMoonlightVideoView?) { self.value = value }
}

nonisolated private func punktfunkFrameSize(
    _ data: Data, chunkAligned: Bool, windowSize: Int
) -> (Int, Int)? {
    func parse(_ bytes: Data) -> (Int, Int)? {
        guard bytes.count >= 8 else { return nil }
        let word0 = bytes.prefix(4).enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
        let word1 = bytes.dropFirst(4).prefix(4).enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << UInt32($1.offset * 8))
        }
        guard word0 & 0x8000_0000 != 0, ((word1 >> 24) & 0x3) == 0 else { return nil }
        return (Int(word0 & 0x3fff) + 1, Int((word0 >> 14) & 0x3fff) + 1)
    }
    guard chunkAligned else { return parse(data) }
    guard windowSize >= 8, data.count % windowSize == 0 else { return nil }
    var fragment = Data()
    var fragmentLive = false
    var offset = 0
    while offset < data.count {
        let used = Int(data[offset]) | (Int(data[offset + 1]) << 8)
        let kind = Int(data[offset + 2]) | (Int(data[offset + 3]) << 8)
        guard used > 0, used <= windowSize - 4 else {
            fragment.removeAll(keepingCapacity: true)
            fragmentLive = false
            offset += windowSize
            continue
        }
        let body = data.subdata(in: (offset + 4)..<(offset + 4 + used))
        switch kind {
        case 0:
            if let size = parse(body) { return size }
            fragment.removeAll(keepingCapacity: true)
            fragmentLive = false
        case 1:
            fragment = body
            fragmentLive = true
        case 2 where fragmentLive:
            fragment.append(body)
        case 3 where fragmentLive:
            fragment.append(body)
            if let size = parse(fragment) { return size }
            fragment.removeAll(keepingCapacity: true)
            fragmentLive = false
        default:
            fragment.removeAll(keepingCapacity: true)
            fragmentLive = false
        }
        offset += windowSize
    }
    return nil
}

private extension Data {
    init(hex: String) {
        self.init()
        reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
    }
}
