import Foundation
import TVServices

actor SteamRecentLibrary {
    static let shared = SteamRecentLibrary()
    static let group = Bundle.main.object(forInfoDictionaryKey: "SteamTVRecentAppGroup") as? String ?? "group.com.josephhewes.SteamAppTV"
    static var store: SteamRecentGamesStore? {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return SteamRecentGamesStore(directory: root.appendingPathComponent("Library/Caches/SteamTVRecentGames"))
    }
    private var lastAttempt: Date = .distantPast
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2; config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()

    static func configure(hostAddress: String? = nil) {
        let defaults = UserDefaults(suiteName: group)!
        if let hostAddress { defaults.set("http://\(hostAddress):27039", forKey: "SteamTV.recentGamesEndpoint") }
        else if defaults.string(forKey: "SteamTV.recentGamesEndpoint") == nil,
                let endpoint = Bundle.main.object(forInfoDictionaryKey: "SteamTVRecentFeedEndpoint") as? String {
            defaults.set(endpoint, forKey: "SteamTV.recentGamesEndpoint")
        }
    }

    func openLibrary(gameID: UInt64, hostAddress: String) async throws {
        guard gameID > 0, let token = Bundle.main.object(forInfoDictionaryKey: "SteamTVRecentFeedToken") as? String,
              let url = URL(string: "http://\(hostAddress):27039/v1/library/\(gameID)") else {
            throw RecentGamesError.invalidFeed
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else {
            throw NSError(domain: "SteamTV", code: 1, userInfo: [NSLocalizedDescriptionKey: "Steam could not open this library entry."])
        }
    }

    func refresh(force: Bool = false) async -> SteamRecentGamesFeed? {
        guard let store = Self.store else { return nil }
        if !force && Date().timeIntervalSince(lastAttempt) < 60 { return store.load() }
        lastAttempt = Date(); Self.configure()
        let defaults = UserDefaults(suiteName: Self.group)!
        guard let endpoint = defaults.string(forKey: "SteamTV.recentGamesEndpoint"),
              let origin = URL(string: endpoint), origin.scheme == "http",
              let host = origin.host,
              host.hasSuffix(".local") || host.hasPrefix("192.168.") || host.hasPrefix("10.") || host == "127.0.0.1",
              let token = Bundle.main.object(forInfoDictionaryKey: "SteamTVRecentFeedToken") as? String
        else { return store.load() }
        do {
            var request = URLRequest(url: origin.appendingPathComponent("v1/recent"))
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await session.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return store.load() }
            let feed = try SteamRecentGamesFeed.decode(data)
            // Fetch artwork concurrently so a sleeping host cannot delay Top Shelf for every tile.
            await withTaskGroup(of: Void.self) { group in
                for game in feed.games {
                    let paths = Bundle.main.object(forInfoDictionaryKey: "SteamTVIsParent") as? Bool == true
                        ? [game.hero, game.background, game.logo] : [game.hero]
                    for path in paths.compactMap({ $0 }) {
                        guard let destination = store.artworkURL(gameID: game.id, path: path) else { continue }
                        if FileManager.default.fileExists(atPath: destination.path) { continue }
                        let session = self.session
                        group.addTask {
                            do {
                                var request = URLRequest(url: origin.appendingPathComponent(String(path.dropFirst())))
                                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                                let (image, response) = try await session.data(for: request)
                                guard (response as? HTTPURLResponse)?.statusCode == 200, image.count <= 8_000_000,
                                      image.starts(with: [0x89, 0x50, 0x4e, 0x47]) || image.starts(with: [0xff, 0xd8]) else { return }
                                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                                try image.write(to: destination, options: .atomic)
                            } catch { }
                        }
                    }
                }
            }
            try store.save(data)
            // Prune artwork for games outside the current feed to keep storage bounded.
            let keep = Set(feed.games.map(\.id))
            if let directories = try? FileManager.default.contentsOfDirectory(at: store.directory.appendingPathComponent("art"), includingPropertiesForKeys: nil) {
                for folder in directories where !keep.contains(folder.lastPathComponent) { try? FileManager.default.removeItem(at: folder) }
            }
            if Bundle.main.object(forInfoDictionaryKey: "SteamTVIsParent") as? Bool == true {
                TVTopShelfContentProvider.topShelfContentDidChange()
            }
            return feed
        } catch { return store.load() }
    }
}
