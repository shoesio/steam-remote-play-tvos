import Foundation

enum SteamTVSettings {
    enum Key {
        static let hostName = "steam.hostName"
        static let hostAddress = "steam.hostAddress"
        static let httpPort = "steam.httpPort"
        static let httpsPort = "steam.httpsPort"
        static let nativePort = "steam.nativePort"
        static let macAddress = "steam.macAddress"
        static let appName = "steam.appName"
        static let appID = "steam.appID"
        static let homeKitOutletName = "steam.homeKitOutletName"
        static let resolution = "steam.resolution"
        static let fps = "steam.fps"
        static let codec = "steam.codec"
        static let automaticBitrate = "steam.automaticBitrate"
        static let bitrateMbps = "steam.bitrateMbps"
        static let optimizeGameSettings = "steam.optimizeGameSettings"
        static let smoothFramePacing = "steam.smoothFramePacing"
        static let exitGameOnClose = "steam.exitGameOnClose"
        static let controllerDeadzone = "steam.controllerDeadzone"
        static let debugOverlay = "steam.debugOverlay"
        static let ambientLightingEnabled = "steam.ambientLightingEnabled"
        static let ambientAccessoryName = "steam.ambientAccessoryName"
        static let ambientUpdateRate = "steam.ambientUpdateRate"
        static let ambientUpdateRateV2 = "steam.ambientUpdateRateV2"
        static let ambientSmoothing = "steam.ambientSmoothing"
        static let ambientIntensity = "steam.ambientIntensity"
        static let ambientAlwaysSaturated = "steam.ambientAlwaysSaturated"
        static let solarflareSettingsMigration = "steam.solarflareSettingsMigration.v1"
    }

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Key.hostName: "BC-250",
            Key.hostAddress: "192.168.0.125",
            Key.httpPort: SunshineHost.defaultHTTPPort,
            Key.httpsPort: SunshineHost.defaultHTTPSPort,
            Key.nativePort: 9777,
            Key.macAddress: "a8:a1:59:b5:e9:6d",
            Key.appName: "Steam Big Picture",
            Key.appID: "",
            Key.homeKitOutletName: "BC-250",
            Key.resolution: "3840x2160",
            Key.fps: 60,
            Key.codec: SunshineVideoCodec.pyroWaveExperimental.rawValue,
            Key.automaticBitrate: false,
            Key.bitrateMbps: 200,
            Key.optimizeGameSettings: false,
            Key.smoothFramePacing: true,
            Key.exitGameOnClose: false,
            Key.controllerDeadzone: 0.15,
            Key.debugOverlay: false,
            Key.ambientLightingEnabled: false,
            Key.ambientAccessoryName: "Behind TV",
            Key.ambientUpdateRate: 3,
            Key.ambientUpdateRateV2: 2,
            Key.ambientSmoothing: 0.72,
            Key.ambientIntensity: 0.75,
            Key.ambientAlwaysSaturated: false,
        ])

        // Replace values introduced by the temporary 1440p compatibility
        // build once, without overriding later choices made in tvOS Settings.
        if !UserDefaults.standard.bool(forKey: Key.solarflareSettingsMigration) {
            if UserDefaults.standard.string(forKey: Key.resolution) == "2560x1440" {
                UserDefaults.standard.set("3840x2160", forKey: Key.resolution)
            }
            if UserDefaults.standard.integer(forKey: Key.bitrateMbps) == 80 {
                UserDefaults.standard.set(200, forKey: Key.bitrateMbps)
            }
            UserDefaults.standard.set(true, forKey: Key.solarflareSettingsMigration)
        }
    }

    static var hostAddress: String { string(Key.hostAddress) }
    static var nativePort: UInt16 { UInt16(clamping: integer(Key.nativePort, fallback: 9777)) }
    static var configuredAppName: String { string(Key.appName) }
    static var configuredAppID: String { string(Key.appID) }
    static var homeKitOutletName: String { string(Key.homeKitOutletName) }
    static var ambientLightingEnabled: Bool { UserDefaults.standard.bool(forKey: Key.ambientLightingEnabled) }
    static var ambientAccessoryName: String {
        let value = string(Key.ambientAccessoryName)
        return value.isEmpty ? "Behind TV" : value
    }
    static var ambientUpdateRate: Double {
        min(max(UserDefaults.standard.double(forKey: Key.ambientUpdateRateV2), 1), 3)
    }
    static var ambientSmoothing: Double { min(max(UserDefaults.standard.double(forKey: Key.ambientSmoothing), 0), 0.9) }
    static var ambientIntensity: Double { min(max(UserDefaults.standard.double(forKey: Key.ambientIntensity), 0.25), 1) }
    static var ambientAlwaysSaturated: Bool { UserDefaults.standard.bool(forKey: Key.ambientAlwaysSaturated) }

    static func host(preserving identity: SunshineHost?) -> SunshineHost {
        let address = hostAddress
        let canPreserveIdentity = identity?.address == address
        return SunshineHost(
            name: string(Key.hostName).isEmpty ? "BC-250" : string(Key.hostName),
            address: address,
            // This direct Solarflare build no longer exposes port overrides.
            // Do not allow hidden values retained from older installs to route
            // discovery and pairing to obsolete Punktfunk/Sunshine ports.
            httpPort: SunshineHost.defaultHTTPPort,
            httpsPort: SunshineHost.defaultHTTPSPort,
            macAddress: string(Key.macAddress),
            webUsername: "sunshine",
            webPassword: "",
            uniqueId: canPreserveIdentity ? identity?.uniqueId : nil,
            serverCertificateDER: canPreserveIdentity ? identity?.serverCertificateDER : nil,
            isPaired: canPreserveIdentity && identity?.isPaired == true
        )
    }

    static var streamSettings: StreamSettings {
        var settings = StreamSettings()
        settings.sunshineResolution = string(Key.resolution)
        settings.sunshineFPS = integer(Key.fps, fallback: 60)
        settings.sunshineCodec = SunshineVideoCodec(rawValue: string(Key.codec)) ?? .pyroWaveExperimental
        settings.sunshineIsBitrateAuto = UserDefaults.standard.bool(forKey: Key.automaticBitrate)
        settings.sunshineMaxBitrateKbps = integer(Key.bitrateMbps, fallback: 400) * 1_000
        settings.sunshineOptimizeGameSettings = UserDefaults.standard.bool(forKey: Key.optimizeGameSettings)
        settings.sunshineSmoothFramePacing = UserDefaults.standard.bool(forKey: Key.smoothFramePacing)
        settings.sunshineExitGameOnStreamClose = UserDefaults.standard.bool(forKey: Key.exitGameOnClose)
        settings.controllerDeadzone = UserDefaults.standard.double(forKey: Key.controllerDeadzone)
        settings.resolution = settings.sunshineResolution
        settings.fps = settings.sunshineFPS
        settings.codec = settings.sunshineCodec.fallbackVideoCodec
        settings.maxBitrateKbps = settings.sunshineIsBitrateAuto
            ? StreamSettings.recommendedSunshineBitrateKbps(
                resolution: settings.sunshineResolution,
                fps: settings.sunshineFPS,
                codec: settings.sunshineCodec
            )
            : settings.sunshineMaxBitrateKbps
        return settings
    }

    static var nativeMode: (width: UInt32, height: UInt32, fps: UInt32) {
        let settings = streamSettings
        let parts = settings.sunshineResolution.split(separator: "x").compactMap { UInt32($0) }
        return (parts.first ?? 3840, parts.dropFirst().first ?? 2160, UInt32(settings.sunshineFPS))
    }

    static var nativeBitrateKbps: UInt32 {
        UInt32(clamping: streamSettings.maxBitrateKbps)
    }

    private static func string(_ key: String) -> String {
        UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func integer(_ key: String, fallback: Int) -> Int {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : fallback
    }
}
