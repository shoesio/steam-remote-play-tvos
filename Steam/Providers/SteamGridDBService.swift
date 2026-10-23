import Foundation
import Security

actor SteamGridDBService {
    static let apiKeyURL = "https://www.steamgriddb.com/profile/preferences/api"

    private let baseURL = URL(string: "https://www.steamgriddb.com/api/v2")!
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func validate(apiKey: String) async throws {
        let response = try await request(path: "search/autocomplete/Portal", apiKey: apiKey)
        guard response.success else { throw SteamGridDBError.invalidKey }
    }

    func heroCandidates(
        title: String,
        steamAppID: String?,
        apiKey: String
    ) async throws -> [GameMetadataArtworkCandidate] {
        guard !apiKey.isEmpty else { return [] }
        let game = try await resolveGame(title: title, steamAppID: steamAppID, apiKey: apiKey)
        guard let game else { return [] }

        let response = try await request(
            path: "heroes/game/\(game.id)",
            query: [
                URLQueryItem(name: "types", value: "static"),
                URLQueryItem(name: "nsfw", value: "false"),
                URLQueryItem(name: "humor", value: "false"),
                URLQueryItem(name: "epilepsy", value: "false")
            ],
            apiKey: apiKey
        )
        let metadata = GameMetadataLookupResult(
            source: .steamGridDB,
            title: game.name,
            releaseDate: nil,
            releaseYear: nil,
            developer: nil,
            publisher: nil,
            genres: [],
            summary: nil,
            externalIds: ExternalGameIds(steamAppId: steamAppID),
            heroArtworkUrl: response.imagesData?.first?.url,
            screenshotUrl: nil
        )
        return (response.imagesData ?? []).prefix(12).map { image in
            GameMetadataArtworkCandidate(
                id: "steamgriddb:\(image.id)",
                title: game.name,
                subtitle: image.style.map { "SteamGridDB · \($0.capitalized)" } ?? "SteamGridDB hero",
                source: .steamGridDB,
                role: .heroBackground,
                url: image.url,
                metadata: metadata
            )
        }
    }

    func coverCandidates(
        title: String,
        steamAppID: String?,
        apiKey: String
    ) async throws -> [GameMetadataArtworkCandidate] {
        guard !apiKey.isEmpty else { return [] }
        let game = try await resolveGame(title: title, steamAppID: steamAppID, apiKey: apiKey)
        guard let game else { return [] }

        let response = try await request(
            path: "grids/game/\(game.id)",
            query: [
                URLQueryItem(name: "types", value: "static"),
                URLQueryItem(name: "dimensions", value: "600x900,342x482,660x930"),
                URLQueryItem(name: "nsfw", value: "false"),
                URLQueryItem(name: "humor", value: "false")
            ],
            apiKey: apiKey
        )
        let metadata = GameMetadataLookupResult(
            source: .steamGridDB,
            title: game.name,
            releaseDate: nil,
            releaseYear: nil,
            developer: nil,
            publisher: nil,
            genres: [],
            summary: nil,
            externalIds: ExternalGameIds(steamAppId: steamAppID),
            heroArtworkUrl: nil,
            screenshotUrl: nil
        )
        return (response.imagesData ?? []).prefix(18).map { image in
            GameMetadataArtworkCandidate(
                id: "steamgriddb:cover:\(image.id)",
                title: game.name,
                subtitle: image.style.map { "SteamGridDB · \($0.capitalized)" } ?? "SteamGridDB cover",
                source: .steamGridDB,
                role: .tileCover,
                url: image.url,
                metadata: metadata
            )
        }
    }

    private func resolveGame(title: String, steamAppID: String?, apiKey: String) async throws -> SteamGridDBGame? {
        if let steamAppID, !steamAppID.isEmpty {
            let response = try? await request(path: "games/steam/\(steamAppID)", apiKey: apiKey)
            if let game = response?.gameData { return game }
        }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        guard let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        let matches = try await request(path: "search/autocomplete/\(encoded)", apiKey: apiKey).gamesData ?? []
        let requested = normalizedTitle(title)
        return matches.first { normalizedTitle($0.name) == requested } ?? matches.first
    }

    private func normalizedTitle(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func request(
        path: String,
        query: [URLQueryItem] = [],
        apiKey: String
    ) async throws -> SteamGridDBResponse {
        guard let endpoint = URL(string: "\(baseURL.absoluteString)/\(path)") else {
            throw SteamGridDBError.invalidResponse
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SteamGridDBError.invalidResponse }
        if http.statusCode == 401 { throw SteamGridDBError.invalidKey }
        guard (200..<300).contains(http.statusCode) else { throw SteamGridDBError.invalidResponse }
        return try JSONDecoder().decode(SteamGridDBResponse.self, from: data)
    }
}

private struct SteamGridDBResponse: Decodable, Sendable {
    let success: Bool
    let payload: SteamGridDBPayload?

    nonisolated var gameData: SteamGridDBGame? {
        if case .game(let game) = payload { return game }
        return nil
    }

    nonisolated var gamesData: [SteamGridDBGame]? {
        if case .games(let games) = payload { return games }
        return nil
    }

    nonisolated var imagesData: [SteamGridDBImage]? {
        if case .images(let images) = payload { return images }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case success, data }

    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = try container.decode(Bool.self, forKey: .success)
        if let images = try? container.decode([SteamGridDBImage].self, forKey: .data) {
            payload = .images(images)
        } else if let games = try? container.decode([SteamGridDBGame].self, forKey: .data) {
            payload = .games(games)
        } else if let game = try? container.decode(SteamGridDBGame.self, forKey: .data) {
            payload = .game(game)
        } else {
            payload = nil
        }
    }
}

private enum SteamGridDBPayload: Sendable {
    case game(SteamGridDBGame)
    case games([SteamGridDBGame])
    case images([SteamGridDBImage])
}

private struct SteamGridDBGame: Decodable, Sendable {
    let id: Int
    let name: String
}

private struct SteamGridDBImage: Decodable, Sendable {
    let id: Int
    let url: String
    let style: String?
}

enum SteamGridDBError: LocalizedError {
    case invalidKey
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidKey: return "SteamGridDB did not accept that API key."
        case .invalidResponse: return "SteamGridDB returned an unexpected response."
        }
    }
}

enum SteamGridDBKeychain {
    private static let service = "com.owenselles.CloudNow.steamgriddb"
    private static let account = "api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = Data(key.utf8)
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw SteamGridDBError.invalidResponse }
    }

    static func delete() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ] as CFDictionary)
    }
}
