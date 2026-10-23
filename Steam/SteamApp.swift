import SwiftUI

@main
struct SteamApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = GamesViewModel()
    @State private var homeKitPowerOutletStore = HomeKitPowerOutletStore.shared
    @State private var sunshineHostStore = SunshineHostStore()

    init() {
        SteamTVSettings.registerDefaults()
        Self.shareSteamGridDBKeyWithTopShelf()
    }

    private static func shareSteamGridDBKeyWithTopShelf() {
        let settingsKey = UserDefaults.standard.string(forKey: "steam.steamGridDBAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sharedDefaults = UserDefaults(suiteName: "group.com.josephhewes.SteamAppTV")
        let storedKey = SteamGridDBKeychain.load()?.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingSharedKey = sharedDefaults?.string(forKey: "steam.steamGridDBAPIKey") ?? ""
        let key = [settingsKey, storedKey, existingSharedKey]
            .compactMap { $0 }
            .first(where: { !$0.isEmpty }) ?? ""
        if !key.isEmpty {
            sharedDefaults?.set(key, forKey: "steam.steamGridDBAPIKey")
        }
        let requestedHours = UserDefaults.standard.integer(forKey: "steam.topShelfRefreshHours")
        sharedDefaults?.set(requestedHours > 0 ? requestedHours : 6, forKey: "steam.topShelfRefreshHours")
        if UserDefaults.standard.bool(forKey: "steam.topShelfRefreshNow") {
            sharedDefaults?.set(
                (sharedDefaults?.integer(forKey: "steam.topShelfRefreshGeneration") ?? 0) + 1,
                forKey: "steam.topShelfRefreshGeneration"
            )
            UserDefaults.standard.set(false, forKey: "steam.topShelfRefreshNow")
        }
        print("[SteamTopShelf] SteamGridDB key shared: \(!key.isEmpty)")
        print("[SteamTopShelf] Last artwork result: \(sharedDefaults?.string(forKey: "steam.steamGridDBLastResult") ?? "not checked")")
    }

    var body: some Scene {
        WindowGroup {
            SteamDirectLaunchView()
                .environment(viewModel)
                .environment(homeKitPowerOutletStore)
                .environment(sunshineHostStore)
                .preferredColorScheme(.dark)
                .preventsTVOSScreenSaverDuringStream()
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Self.shareSteamGridDBKeyWithTopShelf()
                    }
                }
        }
    }
}
