import Foundation

public struct SteamRecentGame: Codable, Sendable {
    public let id: String
    public let title: String
    public let lastPlayed: Int
    public let isShortcut: Bool
    public let summary: String?
    public let genre: String?
    public let developer: String?
    public let publisher: String?
    public let releaseDate: String?
    public let background: String?
    public let hero: String?
    public let logo: String?
    public let exitShortcut: String?

    public func libraryURL(hostID: String) -> URL? {
        guard let number = UInt64(id), number > 0, UInt64(hostID) != nil else { return nil }
        var url = URLComponents()
        url.scheme = "steamtv"; url.host = "library"
        url.queryItems = [URLQueryItem(name: "app", value: id), URLQueryItem(name: "host", value: hostID)]
        return url.url
    }

    public func launchURL(hostID: String) -> URL? {
        guard let number = UInt64(id), number > 0, UInt64(hostID) != nil else { return nil }
        var url = URLComponents()
        url.scheme = "steamtv"; url.host = "launch"
        url.queryItems = [URLQueryItem(name: "app", value: id), URLQueryItem(name: "host", value: hostID)]
        return url.url
    }
}

public struct SteamRecentGamesFeed: Codable, Sendable {
    public let version: Int
    public let generatedAt: Int
    public let hostID: String
    public let hostName: String
    public let games: [SteamRecentGame]

    public static func decode(_ data: Data) throws -> SteamRecentGamesFeed {
        guard data.count <= 256_000 else { throw RecentGamesError.invalidFeed }
        let feed = try JSONDecoder().decode(Self.self, from: data)
        guard feed.version == 1, UInt64(feed.hostID) != nil, feed.games.count <= 16,
              Set(feed.games.map(\.id)).count == feed.games.count,
              feed.games.allSatisfy({ $0.launchURL(hostID: feed.hostID) != nil && !$0.title.isEmpty })
        else { throw RecentGamesError.invalidFeed }
        return feed
    }
}

public enum RecentGamesError: Error { case invalidFeed }

/// Validated, atomic disk storage shared by the parent and its Top Shelf extension.
public struct SteamRecentGamesStore: Sendable {
    public let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func load() -> SteamRecentGamesFeed? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("feed.json")) else { return nil }
        return try? SteamRecentGamesFeed.decode(data)
    }
    public func save(_ data: Data) throws {
        _ = try SteamRecentGamesFeed.decode(data)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("feed.json"), options: .atomic)
    }
    public func artworkURL(gameID: String, path: String) -> URL? {
        guard UInt64(gameID) != nil else { return nil }
        let components = path.split(separator: "/").map(String.init)
        guard components.count == 3, components[0] == "art", components[1] == gameID,
              (["hero.png", "hero.jpg", "hero.jpeg", "logo.png", "logo.jpg", "logo.jpeg"].contains(components[2]) || components[2].range(of: "^hero-logo-[0-9a-f]{12}\\.jpg$", options: .regularExpression) != nil) else { return nil }
        return directory.appendingPathComponent("art").appendingPathComponent(gameID).appendingPathComponent(components[2])
    }
}
