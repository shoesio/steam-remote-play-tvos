import Foundation
import Observation

@MainActor
@Observable
final class XCloudLibraryStore {
    private(set) var games: [XCloudGame] = []
    private(set) var homePlaylists: XCloudHomePlaylists = .empty
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private static var cacheDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CloudNow", isDirectory: true)
            .appendingPathComponent("XCloud", isDirectory: true)
    }

    private static var gamesCacheURL: URL? {
        cacheDirectory?.appendingPathComponent("entitled-library-v2.json")
    }

    private static var playlistsCacheURL: URL? {
        cacheDirectory?.appendingPathComponent("home-playlists-v2.json")
    }

    init() {
        if let url = Self.gamesCacheURL,
           let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode([XCloudGame].self, from: data) {
            games = cached.map { game in
                Self.normalizedGame(game)
            }
        }
        if let url = Self.playlistsCacheURL,
           let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(XCloudHomePlaylists.self, from: data) {
            homePlaylists = XCloudHomePlaylists(
                newOnXCloud: cached.newOnXCloud.map(Self.normalizedGame),
                mostPopular: cached.mostPopular.map(Self.normalizedGame)
            )
        }
    }

    var gameInfos: [GameInfo] { games.map(\.gameInfo) }
    var newOnXCloudGameInfos: [GameInfo] { homePlaylists.newOnXCloud.map(\.gameInfo) }
    var mostPopularGameInfos: [GameInfo] { homePlaylists.mostPopular.map(\.gameInfo) }

    func game(titleID: String) -> XCloudGame? {
        games.first { $0.id == titleID }
    }

    func load(auth: XCloudAuthManager, force: Bool = false) async {
        guard auth.isSignedIn else { return }
        guard force || games.isEmpty else { return }
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let credentials = try await auth.resolvedCredentials()
            let client = XCloudClient(credentials: credentials)
            games = try await client.games()
            homePlaylists = await client.homePlaylists(from: games)
            persistCaches()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clear() {
        games = []
        homePlaylists = .empty
        errorMessage = nil
        if let url = Self.gamesCacheURL { try? FileManager.default.removeItem(at: url) }
        if let url = Self.playlistsCacheURL { try? FileManager.default.removeItem(at: url) }
    }

    private func persistCaches() {
        guard let directory = Self.cacheDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let url = Self.gamesCacheURL,
           let data = try? JSONEncoder().encode(games) {
            try? data.write(to: url, options: .atomic)
        }
        if let url = Self.playlistsCacheURL,
           let data = try? JSONEncoder().encode(homePlaylists) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func normalizedGame(_ game: XCloudGame) -> XCloudGame {
        XCloudGame(
            id: game.id,
            productID: game.productID,
            title: XCloudTitleFormatter.displayTitle(game.title),
            supportsController: game.supportsController,
            hasEntitlement: game.hasEntitlement,
            boxArtURL: game.boxArtURL,
            heroArtURL: game.heroArtURL,
            providerMetadata: game.providerMetadata
        )
    }
}
