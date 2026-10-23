import Foundation

enum SteamSharedSettings {
    static let group = "group.com.josephhewes.SteamAppTV"
    static let defaults = UserDefaults(suiteName: group)!
    static func prepare() {
        // The main app is the sole migration source and Settings panel owner.
        if Bundle.main.object(forInfoDictionaryKey: "SteamTVIsParent") as? Bool == true, !defaults.bool(forKey: "SteamTV.sharedSettingsMigrated") {
            for key in ["SteamTV.hostName", "SteamTV.homeSwitch", "SteamTV.deadzone", "SteamTV.lastHostID", "SteamTV.preferredVideoCodec"] {
                if let value = UserDefaults.standard.object(forKey: key) { defaults.set(value, forKey: key) }
            }
            defaults.set(true, forKey: "SteamTV.sharedSettingsMigrated")
        }
        defaults.register(defaults: ["SteamTV.hostName": "bc-250", "SteamTV.homeSwitch": "BC-250", "SteamTV.deadzone": 0.15, "SteamTV.preferredVideoCodec": 9])
    }
    static func profileKey(host: UInt64, codec: SteamVideoCodec) -> String { "SteamTV.videoPreferences.\(host).\(codec.rawValue)" }
}
