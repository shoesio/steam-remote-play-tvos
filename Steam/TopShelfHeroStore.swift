import Foundation
import TVServices

struct TopShelfHeroSnapshot: Codable {
    let savedAt: Date
    let items: [TopShelfHeroItem]
}

struct TopShelfHeroItem: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let provider: String
    let imageURL: String?
    let fallbackImageURL: String?
    let playURL: String
    let displayURL: String
}

enum TopShelfHeroStore {
    static let appGroupIdentifier = "group.com.josephhewes.CloudNowAppTV"
    static let storageKey = "topShelf.heroSnapshot"

    static func saveHeroes(_ games: [GameInfo]) {
        let items = games.prefix(8).map { game in
            TopShelfHeroItem(
                id: game.id,
                title: game.title,
                provider: providerLabel(for: game),
                imageURL: heroImageURL(for: game)?.absoluteString,
                fallbackImageURL: coverImageURL(for: game)?.absoluteString,
                playURL: actionURL(action: "play", gameID: game.id),
                displayURL: actionURL(action: "game", gameID: game.id)
            )
        }
        if let existingData = defaults.data(forKey: storageKey),
           let existingSnapshot = try? JSONDecoder().decode(TopShelfHeroSnapshot.self, from: existingData),
           existingSnapshot.items == items {
            return
        }

        let snapshot = TopShelfHeroSnapshot(savedAt: Date(), items: items)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
        defaults.synchronize()
        TVTopShelfContentProvider.topShelfContentDidChange()
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }

    private static func heroImageURL(for game: GameInfo) -> URL? {
        guard var raw = game.heroBannerUrl, !raw.isEmpty else { return nil }
        guard raw.contains("img.nvidiagrid.net") else { return URL(string: raw) }
        if let range = raw.range(of: ";w=") {
            raw = String(raw[..<range.lowerBound])
        }
        return URL(string: "\(raw);w=1920")
    }

    private static func coverImageURL(for game: GameInfo) -> URL? {
        guard let raw = game.boxArtUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    private static func providerLabel(for game: GameInfo) -> String {
        if game.isXCloudGame { return "Xbox Cloud Gaming" }
        if game.isSunshineGame { return "Sunshine" }
        return "GeForce NOW"
    }

    private static func actionURL(action: String, gameID: String) -> String {
        var components = URLComponents()
        components.scheme = "cloudnow"
        components.host = action
        components.queryItems = [URLQueryItem(name: "id", value: gameID)]
        return components.url?.absoluteString ?? "cloudnow://home"
    }
}
