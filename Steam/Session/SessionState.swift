import Foundation

// MARK: - Stream Settings

struct StreamSettings: Codable, Equatable {
    var resolution: String = "1920x1080"
    /// Sunshine has its own resolution because GFN choices are entitlement-limited.
    var sunshineResolution: String = "1920x1080"
    var sunshineFPS: Int = 60
    var sunshineCodec: SunshineVideoCodec = .automatic
    var sunshineIsBitrateAuto: Bool = true
    var sunshineMaxBitrateKbps: Int = 25_000
    /// Ask Sunshine/GameStream to apply host-side game optimizations. Mirrors Moonlight's "Optimize game settings".
    var sunshineOptimizeGameSettings: Bool = true
    /// Smooth frame pacing for the Moonlight renderer. Mirrors Moonlight's "Smooth" frame pacing choice.
    var sunshineSmoothFramePacing: Bool = true
    /// Send Sunshine's quit/cancel request when the Moonlight stream closes.
    var sunshineExitGameOnStreamClose: Bool = true
    var fps: Int = 60
    var isBitrateAuto: Bool = true
    var maxBitrateKbps: Int = StreamSettings.recommendedBitrateKbps(resolution: "1920x1080", fps: 60) {
        // Sunshine/PyroWave copies its independent bitrate into this shared
        // Moonlight request object immediately before launch. Its UI permits
        // up to 500 Mbps, while the conventional GFN UI still caps itself at
        // 100 Mbps, so preserve the higher Sunshine request here.
        didSet { maxBitrateKbps = min(max(maxBitrateKbps, 15_000), 500_000) }
    }
    var codec: VideoCodec = .h264
    var colorQuality: ColorQuality = .sdr8bit
    var keyboardLayout: String = "en-US"
    var gameLanguage: String = "en_US"
    var enableL4S: Bool = false
    var micEnabled: Bool = false
    /// Radial deadzone applied to analog stick axes (0.0–1.0). Default 15%.
    var controllerDeadzone: Double = 0.15
    /// Which controller button triggers the GFN overlay on long-press. Default: Start (≡).
    var overlayTriggerButton: OverlayTriggerButton = .start
    /// Default Siri Remote input mode when a stream session starts.
    var defaultRemoteInputMode: RemoteInputMode = .mouse
    /// Preferred zone URL, e.g. "https://np-aws-us-n-virginia-1.cloudmatchbeta.nvidiagrid.net/"
    /// nil = let the GFN default VPC handle routing.
    var preferredZoneUrl: String? = nil
    /// Long-press the button that is NOT the overlay trigger to send Shift+Tab (opens the
    /// Steam in-game overlay). e.g. with overlay on Start, long-press View/Back triggers Steam.
    var enableSteamOverlayGesture: Bool = true
}

// MARK: - StreamSettings: resilient decoding
//
// Synthesized Decodable throws keyNotFound when a newly-added field is missing from
// previously-persisted JSON, which would silently reset ALL settings to defaults on upgrade.
// decodeIfPresent + default fallbacks keep existing settings intact across versions.
extension StreamSettings {
    enum CodingKeys: String, CodingKey {
        case resolution, sunshineResolution, sunshineFPS, sunshineCodec, sunshineIsBitrateAuto, sunshineMaxBitrateKbps
        case sunshineOptimizeGameSettings, sunshineSmoothFramePacing, sunshineExitGameOnStreamClose
        case fps, isBitrateAuto, maxBitrateKbps, codec, colorQuality, keyboardLayout
        case gameLanguage, enableL4S, micEnabled, controllerDeadzone, overlayTriggerButton
        case defaultRemoteInputMode, preferredZoneUrl
        case enableSteamOverlayGesture
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = StreamSettings()
        self.init()
        resolution            = try c.decodeIfPresent(String.self,            forKey: .resolution)            ?? d.resolution
        fps                   = try c.decodeIfPresent(Int.self,               forKey: .fps)                   ?? d.fps
        isBitrateAuto         = try c.decodeIfPresent(Bool.self,              forKey: .isBitrateAuto)         ?? d.isBitrateAuto
        maxBitrateKbps        = try c.decodeIfPresent(Int.self,               forKey: .maxBitrateKbps)        ?? d.maxBitrateKbps
        codec                 = try c.decodeIfPresent(VideoCodec.self,        forKey: .codec)                 ?? d.codec
        // Migrate existing installs by inheriting their former shared GFN values once.
        sunshineResolution    = try c.decodeIfPresent(String.self,            forKey: .sunshineResolution)    ?? resolution
        sunshineFPS           = try c.decodeIfPresent(Int.self,               forKey: .sunshineFPS)           ?? fps
        sunshineCodec         = try c.decodeIfPresent(SunshineVideoCodec.self, forKey: .sunshineCodec)        ?? d.sunshineCodec
        sunshineIsBitrateAuto = try c.decodeIfPresent(Bool.self,              forKey: .sunshineIsBitrateAuto) ?? isBitrateAuto
        sunshineMaxBitrateKbps = try c.decodeIfPresent(Int.self,              forKey: .sunshineMaxBitrateKbps) ?? maxBitrateKbps
        sunshineOptimizeGameSettings = try c.decodeIfPresent(Bool.self,       forKey: .sunshineOptimizeGameSettings) ?? d.sunshineOptimizeGameSettings
        sunshineSmoothFramePacing = try c.decodeIfPresent(Bool.self,          forKey: .sunshineSmoothFramePacing) ?? d.sunshineSmoothFramePacing
        sunshineExitGameOnStreamClose = try c.decodeIfPresent(Bool.self,      forKey: .sunshineExitGameOnStreamClose) ?? d.sunshineExitGameOnStreamClose
        colorQuality          = try c.decodeIfPresent(ColorQuality.self,      forKey: .colorQuality)          ?? d.colorQuality
        keyboardLayout        = try c.decodeIfPresent(String.self,            forKey: .keyboardLayout)        ?? d.keyboardLayout
        gameLanguage          = try c.decodeIfPresent(String.self,            forKey: .gameLanguage)          ?? d.gameLanguage
        enableL4S             = try c.decodeIfPresent(Bool.self,              forKey: .enableL4S)             ?? d.enableL4S
        micEnabled            = try c.decodeIfPresent(Bool.self,              forKey: .micEnabled)            ?? d.micEnabled
        controllerDeadzone    = try c.decodeIfPresent(Double.self,            forKey: .controllerDeadzone)    ?? d.controllerDeadzone
        overlayTriggerButton  = try c.decodeIfPresent(OverlayTriggerButton.self, forKey: .overlayTriggerButton) ?? d.overlayTriggerButton
        defaultRemoteInputMode = try c.decodeIfPresent(RemoteInputMode.self,  forKey: .defaultRemoteInputMode) ?? d.defaultRemoteInputMode
        preferredZoneUrl      = try c.decodeIfPresent(String.self,            forKey: .preferredZoneUrl)
        enableSteamOverlayGesture = try c.decodeIfPresent(Bool.self,         forKey: .enableSteamOverlayGesture) ?? d.enableSteamOverlayGesture
        if isBitrateAuto {
            applyRecommendedBitrate()
        }
        if sunshineIsBitrateAuto {
            sunshineMaxBitrateKbps = Self.recommendedSunshineBitrateKbps(
                resolution: sunshineResolution,
                fps: sunshineFPS,
                codec: sunshineCodec
            )
        }
    }

    var recommendedBitrateKbps: Int {
        Self.recommendedBitrateKbps(resolution: resolution, fps: fps)
    }

    mutating func applyRecommendedBitrate() {
        maxBitrateKbps = recommendedBitrateKbps
    }

    static func recommendedBitrateKbps(resolution: String, fps: Int) -> Int {
        let parts = resolution.split(separator: "x").compactMap { Int($0) }
        let width = parts.first ?? 1920
        let height = parts.dropFirst().first ?? 1080
        let pixels = width * height

        switch pixels {
        case ..<(1600 * 900):
            return 15_000
        case ..<(2300 * 1300):
            return 25_000
        case ..<(3600 * 1800):
            return fps > 60 ? 35_000 : 30_000
        case ..<(4600 * 2600):
            return fps > 60 ? 45_000 : 40_000
        default:
            return fps > 60 ? 65_000 : 50_000
        }
    }

    static func recommendedSunshineBitrateKbps(
        resolution: String,
        fps: Int,
        codec: SunshineVideoCodec
    ) -> Int {
        guard codec == .pyroWaveExperimental else {
            return recommendedBitrateKbps(resolution: resolution, fps: fps)
        }

        let parts = resolution.split(separator: "x").compactMap { Int($0) }
        let width = parts.first ?? 1920
        let height = parts.dropFirst().first ?? 1080
        let pixels = width * height

        switch pixels {
        case ..<(1600 * 900):
            return fps <= 30 ? 50_000 : 75_000
        case ..<(2300 * 1300):
            return fps <= 30 ? 100_000 : 150_000
        case ..<(3600 * 1800):
            return fps <= 30 ? 150_000 : 200_000
        default:
            return fps <= 30 ? 250_000 : 400_000
        }
    }

    static func maximumSunshineBitrateKbps(codec: SunshineVideoCodec) -> Int {
        codec == .pyroWaveExperimental ? 500_000 : 100_000
    }

    static func sunshineBitrateStepKbps(codec: SunshineVideoCodec) -> Int {
        codec == .pyroWaveExperimental ? 25_000 : 5_000
    }
}

enum OverlayTriggerButton: String, Codable, CaseIterable {
    case start   = "Start (≡)"
    case options = "Options/Back (⊟)"
}

enum VideoCodec: String, Codable, CaseIterable {
    case h264 = "H264"
    case h265 = "H265"
    case av1  = "AV1"
}

enum SunshineVideoCodec: String, Codable, CaseIterable {
    case automatic = "Automatic"
    case h264 = "H264"
    case pyroWaveExperimental = "PyroWaveExperimental"

    init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        switch rawValue {
        case Self.automatic.rawValue:
            self = .automatic
        case Self.h264.rawValue, "H265", "AV1":
            self = .h264
        case Self.pyroWaveExperimental.rawValue, "PyroWave":
            self = .pyroWaveExperimental
        default:
            self = .automatic
        }
    }

    var fallbackVideoCodec: VideoCodec {
        switch self {
        case .automatic, .h264, .pyroWaveExperimental:
            return .h264
        }
    }

    var moonlightPreferredVideoCodec: CNMoonlightPreferredVideoCodec {
        switch self {
        case .automatic:
            return CNMoonlightPreferredVideoCodec(rawValue: 0)!
        case .h264:
            return CNMoonlightPreferredVideoCodec(rawValue: 1)!
        case .pyroWaveExperimental:
            return CNMoonlightPreferredVideoCodec(rawValue: 2)!
        }
    }
}

enum ColorQuality: String, Codable, CaseIterable {
    case sdr8bit  = "SDR8bit"
    case sdr10bit = "SDR10bit"
    case hdr10bit = "HDR10bit"

    var bitDepth: Int { self == .sdr8bit ? 8 : 10 }
    var chromaFormat: Int { self == .hdr10bit ? 2 : 1 }
}

// MARK: - ICE Server

struct IceServer: Codable {
    let urls: [String]
    let username: String?
    let credential: String?
}

// MARK: - Queue Ads

struct SessionAdMediaFile: Codable, Equatable {
    let mediaFileUrl: String?
    let encodingProfile: String?
}

struct SessionAdInfo: Codable, Equatable, Identifiable {
    let adId: String
    let adUrl: String?
    let mediaUrl: String?
    let adMediaFiles: [SessionAdMediaFile]
    let adLengthInSeconds: Double?
    var id: String { adId }

    /// Returns the best available media URL.
    var preferredMediaURL: URL? {
        if let url = adMediaFiles.compactMap({ $0.mediaFileUrl.flatMap(URL.init) }).first { return url }
        if let url = adUrl.flatMap(URL.init) { return url }
        return mediaUrl.flatMap(URL.init)
    }
}

struct SessionAdState: Codable, Equatable {
    let isAdsRequired: Bool
    let isQueuePaused: Bool?
    let gracePeriodSeconds: Int?
    let message: String?
    let ads: [SessionAdInfo]
}

// MARK: - Session Info (returned by CloudMatch)

struct SessionInfo: Codable {
    let sessionId: String
    let subSessionId: String?
    let status: Int
    let zone: String
    let streamingBaseUrl: String
    let serverIp: String
    let signalingServer: String
    let signalingUrl: String
    let gpuType: String?
    let queuePosition: Int?
    let seatSetupStep: Int?
    let iceServers: [IceServer]
    let mediaConnectionInfo: MediaConnectionInfo?
    let clientId: String
    let deviceId: String
    let adState: SessionAdState?

    /// True while the session is sitting in the GFN queue (no timeout applies).
    var isInQueue: Bool {
        if seatSetupStep == 1 { return true }
        return (queuePosition ?? 0) > 1
    }

    var isEmptyPlaceholder: Bool {
        status == 0
            && !Self.isValidHost(serverIp)
            && mediaConnectionInfo == nil
            && !isInQueue
    }

    var hasValidResumeEndpoint: Bool {
        Self.isValidHost(serverIp)
    }

    static func isValidHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && !trimmed.hasPrefix(".")
            && trimmed.contains(".")
    }
}

struct MediaConnectionInfo: Codable {
    let ip: String
    let port: Int
}

// MARK: - Active Session Info

struct ActiveSessionInfo: Codable {
    let sessionId: String
    let status: Int
    let appId: String?
    let serverIp: String?
    let signalingUrl: String?
}

// MARK: - Subscription / Entitlements

struct EntitledResolution: Equatable {
    let widthInPixels: Int
    let heightInPixels: Int
    let framesPerSecond: Int

    var resolutionLabel: String { "\(widthInPixels)x\(heightInPixels)" }
}

struct SubscriptionInfo {
    let membershipTier: String
    let isUnlimited: Bool
    let remainingMinutes: Int?
    let totalMinutes: Int?
    let entitledResolutions: [EntitledResolution]
}

// MARK: - Games

struct GameProviderMetadata: Equatable, Hashable, Codable, Sendable {
    var platform: String?
    var releaseDate: String?
    var releaseYear: Int?
    var developer: String?
    var publisher: String?
    var genres: [String]
    var summary: String?
}

struct GameInfo: Identifiable, Equatable, Codable {
    let id: String
    let title: String
    let boxArtUrl: String?
    let heroBannerUrl: String?
    var isInLibrary: Bool
    var variants: [GameVariant]
    var canonicalId: String? = nil
    var matchConfidence: Double? = nil
    var matchSource: String? = nil
    var needsReview: Bool = false
    var providerMetadata: GameProviderMetadata? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, boxArtUrl, heroBannerUrl, isInLibrary, variants
        case canonicalId, matchConfidence, matchSource, needsReview, providerMetadata
    }

    init(
        id: String,
        title: String,
        boxArtUrl: String?,
        heroBannerUrl: String?,
        isInLibrary: Bool,
        variants: [GameVariant],
        canonicalId: String? = nil,
        matchConfidence: Double? = nil,
        matchSource: String? = nil,
        needsReview: Bool = false,
        providerMetadata: GameProviderMetadata? = nil
    ) {
        self.id = id
        self.title = title
        self.boxArtUrl = boxArtUrl
        self.heroBannerUrl = heroBannerUrl
        self.isInLibrary = isInLibrary
        self.variants = variants
        self.canonicalId = canonicalId
        self.matchConfidence = matchConfidence
        self.matchSource = matchSource
        self.needsReview = needsReview
        self.providerMetadata = providerMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        boxArtUrl = try container.decodeIfPresent(String.self, forKey: .boxArtUrl)
        heroBannerUrl = try container.decodeIfPresent(String.self, forKey: .heroBannerUrl)
        isInLibrary = try container.decode(Bool.self, forKey: .isInLibrary)
        variants = try container.decode([GameVariant].self, forKey: .variants)
        canonicalId = try container.decodeIfPresent(String.self, forKey: .canonicalId)
        matchConfidence = try container.decodeIfPresent(Double.self, forKey: .matchConfidence)
        matchSource = try container.decodeIfPresent(String.self, forKey: .matchSource)
        needsReview = try container.decodeIfPresent(Bool.self, forKey: .needsReview) ?? false
        providerMetadata = try container.decodeIfPresent(GameProviderMetadata.self, forKey: .providerMetadata)
    }

    /// Whether this game belongs under a store filter. Owned games match only the store they're
    /// owned through; unowned catalog games match any store they're available on.
    func matchesStore(_ store: String) -> Bool {
        if isInLibrary {
            return variants.contains { $0.appStore == store && $0.isOwned }
        }
        return variants.contains { $0.appStore == store }
    }

    /// Stores this game is owned through (drives the Library filter chips).
    var ownedStores: [String] {
        variants.filter { $0.isOwned }.map { $0.appStore }
    }
}

struct GameVariant: Equatable, Codable {
    let id: String
    let appStore: String
    var appId: String?
    /// True when this variant is the one in the GFN library (`gfn.library.selected`) —
    /// i.e. the store the game is owned through.
    var isOwned: Bool = false

    var storeName: String {
        switch appStore {
        case "STEAM": return "Steam"
        case "EPIC_GAMES_STORE": return "Epic Games"
        case "GOG": return "GOG"
        case "EA_APP": return "EA App"
        case "UBISOFT": return "Ubisoft Connect"
        case "MICROSOFT", "XBOX": return "Xbox"
        case "SUNSHINE": return "Sunshine"
        case "XCLOUD": return "Xbox Cloud Gaming"
        case "BATTLENET": return "Battle.net"
        default: return appStore.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Session Create Request

struct SessionCreateRequest {
    let appId: String
    let internalTitle: String?
    let token: String
    let zone: String
    let streamingBaseUrl: String?
    let settings: StreamSettings
    let accountLinked: Bool
}
