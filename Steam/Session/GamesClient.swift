import Foundation

// MARK: - GamesClient

/// Fetches the GFN game library via the GraphQL persisted-query API.
actor GamesClient {
    private static let graphqlURL = "https://games.geforce.com/graphql"
    private static let websiteCatalogURL = "https://api-prod.nvidia.com/services/gfngames/v1/gameList"
    private static let panelsQueryHash = "f8e26265a5db5c20e1334a6872cf04b6e3970507697f6ae55a6ddefa5420daf0"
    private static let metadataQueryHash = "39187e85b6dcf60b7279a5f233288b0a8b69a8b1dbcfb5b25555afdcb988f0d7"
    private static let clientId = "ec7e38d4-03af-4b58-b131-cfb0495903ab"
    private static let clientVersion = "2.0.80.173"
    private static let catalogPageSize = 500

    private let urlSession = URLSession.shared

    // MARK: Fetch Main Game List

    func fetchMainGames(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl) async throws -> [GameInfo] {
        let vpcId = (try? await fetchVpcId(token: token, baseUrl: streamingBaseUrl)) ?? "GFN-PC"
        var games = try await fetchPanels(token: token, panelNames: ["MAIN"], vpcId: vpcId)
        games = (try? await enrich(token: token, vpcId: vpcId, games: games)) ?? games
        return games
    }

    // MARK: Fetch Library (owned/purchased games)

    func fetchLibrary(token: String, streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl) async throws -> [GameInfo] {
        let vpcId = (try? await fetchVpcId(token: token, baseUrl: streamingBaseUrl)) ?? "GFN-PC"
        var games = try await fetchPanels(token: token, panelNames: ["LIBRARY"], vpcId: vpcId)
        games = (try? await enrich(token: token, vpcId: vpcId, games: games)) ?? games
        return games
    }

    // MARK: Fetch Public Supported Catalog

    func fetchPublicCatalog(streamingBaseUrl: String = NVIDIAAuth.defaultStreamingUrl) async throws -> [GameInfo] {
        let vpcId = (try? await fetchPublicVpcId(baseUrl: streamingBaseUrl)) ?? "GFN-PC"
        var gamesById: [String: GameInfo] = [:]
        var orderedIds: [String] = []
        var after = ""
        var pageCount = 0

        repeat {
            let payload = try await fetchWebsiteCatalogPage(after: after, vpcId: vpcId)
            for item in payload.data.apps.items {
                guard let game = item.toGameInfo() else { continue }
                if var existing = gamesById[game.id] {
                    let existingVariantIds = Set(existing.variants.map(\.id))
                    existing.variants.append(contentsOf: game.variants.filter { !existingVariantIds.contains($0.id) })
                    gamesById[game.id] = GameInfo(
                        id: existing.id,
                        title: existing.title,
                        boxArtUrl: existing.boxArtUrl ?? game.boxArtUrl,
                        heroBannerUrl: existing.heroBannerUrl ?? game.heroBannerUrl,
                        isInLibrary: existing.isInLibrary || game.isInLibrary,
                        variants: existing.variants,
                        providerMetadata: existing.providerMetadata ?? game.providerMetadata
                    )
                } else {
                    gamesById[game.id] = game
                    orderedIds.append(game.id)
                }
            }
            pageCount += 1
            after = payload.data.apps.pageInfo.endCursor ?? ""
            if !payload.data.apps.pageInfo.hasNextPage { break }
        } while !after.isEmpty && pageCount < 20

        return orderedIds.compactMap { gamesById[$0] }
    }

    private func fetchWebsiteCatalogPage(after: String, vpcId: String) async throws -> WebsiteCatalogResponse {
        let body = """
        { apps(country:"US" language:"en_US" orderBy: "itemMetadata.gfnPopularityRank:ASC,sortName:ASC" after:"\(after)" first:\(GamesClient.catalogPageSize) vpcId:"\(vpcId)") { numberReturned pageInfo { endCursor hasNextPage } items { id title sortName gfn { playType minimumMembershipTierLabel } variants { id appStore publisherName minimumSizeInBytes } images { GAME_BOX_ART TV_BANNER HERO_IMAGE FEATURE_IMAGE } } } }
        """
        var request = URLRequest(url: URL(string: GamesClient.websiteCatalogURL)!)
        request.httpMethod = "POST"
        request.httpBody = body.data(using: .utf8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GamesError.fetchFailed(String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(WebsiteCatalogResponse.self, from: data)
    }

    // MARK: - Metadata Enrichment

    private func enrich(token: String, vpcId: String, games: [GameInfo]) async throws -> [GameInfo] {
        let ids = Array(Set(games.map(\.id)))
        guard !ids.isEmpty else { return games }

        var metaById: [String: AppData] = [:]
        let chunkSize = 40

        for start in stride(from: 0, to: ids.count, by: chunkSize) {
            let chunk = Array(ids[start..<min(start + chunkSize, ids.count)])
            let payload = try await fetchMetadata(token: token, appIds: chunk, vpcId: vpcId)
            for app in payload {
                guard let rawId = app.id else { continue }
                metaById[rawId.stringValue] = app
            }
        }

        return games.map { game in
            guard let meta = metaById[game.id] else { return game }
            let boxArt = meta.images?.GAME_BOX_ART.flatMap { optimizeImageUrl($0) }
            let hero   = (meta.images?.TV_BANNER ?? meta.images?.HERO_IMAGE).flatMap { optimizeImageUrl($0, width: 1920) }
            return GameInfo(
                id: game.id,
                title: meta.title ?? game.title,
                boxArtUrl: boxArt ?? game.boxArtUrl,
                heroBannerUrl: hero ?? game.heroBannerUrl,
                isInLibrary: game.isInLibrary,
                variants: game.variants,
                providerMetadata: mergedProviderMetadata(game.providerMetadata, gfnMetadata(from: meta.variants))
            )
        }
    }

    private func fetchMetadata(token: String, appIds: [String], vpcId: String) async throws -> [AppData] {
        let variables: [String: Any] = ["vpcId": vpcId, "locale": "en_US", "appIds": appIds]
        let extensions: [String: Any] = ["persistedQuery": ["sha256Hash": GamesClient.metadataQueryHash]]
        let huId = "\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 16))\(String(Int.random(in: 0..<Int.max), radix: 16))"

        var comps = URLComponents(string: GamesClient.graphqlURL)!
        comps.queryItems = [
            URLQueryItem(name: "requestType", value: "appMetaData"),
            URLQueryItem(name: "extensions", value: jsonString(extensions)),
            URLQueryItem(name: "huId", value: huId),
            URLQueryItem(name: "variables", value: jsonString(variables)),
        ]
        var request = URLRequest(url: comps.url!)
        setGFNHeaders(on: &request, token: token)

        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GamesError.fetchFailed(String(data: data, encoding: .utf8) ?? "")
        }
        let payload = try JSONDecoder().decode(MetadataResponse.self, from: data)
        return payload.data?.apps.items ?? []
    }

    // MARK: - Panels

    private func fetchVpcId(token: String, baseUrl: String) async throws -> String {
        let base = baseUrl.hasSuffix("/") ? baseUrl : "\(baseUrl)/"
        let url = URL(string: "\(base)v2/serverInfo")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(GamesClient.clientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("NVIDIA-CLASSIC", forHTTPHeaderField: "nv-client-streamer")
        let (data, _) = try await urlSession.data(for: request)
        let payload = try JSONDecoder().decode(ServerInfoResponse.self, from: data)
        return payload.requestStatus?.serverId ?? "GFN-PC"
    }

    private func fetchPublicVpcId(baseUrl: String) async throws -> String {
        let base = baseUrl.hasSuffix("/") ? baseUrl : "\(baseUrl)/"
        let url = URL(string: "\(base)v2/serverInfo")!
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await urlSession.data(for: request)
        let payload = try JSONDecoder().decode(ServerInfoResponse.self, from: data)
        return payload.requestStatus?.serverId ?? "GFN-PC"
    }

    private func fetchPanels(token: String, panelNames: [String], vpcId: String) async throws -> [GameInfo] {
        let variables: [String: Any] = ["vpcId": vpcId, "locale": "en_US", "panelNames": panelNames]
        let extensions: [String: Any] = ["persistedQuery": ["sha256Hash": GamesClient.panelsQueryHash]]
        let requestType = panelNames.contains("LIBRARY") ? "panels/Library" : "panels/MainV2"
        let huId = "\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 16))\(String(Int.random(in: 0..<Int.max), radix: 16))"

        var comps = URLComponents(string: GamesClient.graphqlURL)!
        comps.queryItems = [
            URLQueryItem(name: "requestType", value: requestType),
            URLQueryItem(name: "extensions", value: jsonString(extensions)),
            URLQueryItem(name: "huId", value: huId),
            URLQueryItem(name: "variables", value: jsonString(variables)),
        ]
        var request = URLRequest(url: comps.url!)
        setGFNHeaders(on: &request, token: token)

        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GamesError.fetchFailed(String(data: data, encoding: .utf8) ?? "")
        }
        let payload = try JSONDecoder().decode(PanelsResponse.self, from: data)
        return flattenPanels(payload)
    }

    private func flattenPanels(_ payload: PanelsResponse) -> [GameInfo] {
        var games: [GameInfo] = []
        var seen = Set<String>()
        for panel in payload.data?.panels ?? [] {
            for section in panel.sections ?? [] {
                for item in section.items ?? [] {
                    guard item.__typename == "GameItem", let app = item.app else { continue }
                    if let game = appToGame(app), seen.insert(game.id).inserted {
                        games.append(game)
                    }
                }
            }
        }
        return games
    }

    private func appToGame(_ app: AppData) -> GameInfo? {
        guard let rawId = app.id else { return nil }
        let id = rawId.stringValue
        var variants: [GameVariant] = app.variants?.compactMap { v in
            guard let vid = v.id else { return nil }
            return GameVariant(
                id: vid,
                appStore: v.appStore ?? "unknown",
                appId: isNumericId(vid) ? vid : nil,
                isOwned: v.gfn?.library?.selected == true
            )
        } ?? []

        // Move the backend-selected variant to front so variants.first is the default launch store
        let selectedIndex = app.variants?.firstIndex { $0.gfn?.library?.selected == true } ?? 0
        let safeIndex = min(max(0, selectedIndex), max(0, variants.count - 1))
        if safeIndex > 0 && safeIndex < variants.count {
            let selected = variants.remove(at: safeIndex)
            variants.insert(selected, at: 0)
        }

        return GameInfo(
            id: id,
            title: app.title ?? id,
            boxArtUrl: app.images?.GAME_BOX_ART.flatMap { optimizeImageUrl($0) },
            heroBannerUrl: (app.images?.TV_BANNER ?? app.images?.HERO_IMAGE).flatMap { optimizeImageUrl($0, width: 1920) },
            isInLibrary: app.variants?.contains { $0.gfn?.library?.selected == true } ?? false,
            variants: variants,
            providerMetadata: gfnMetadata(from: app.variants)
        )
    }

    private func gfnMetadata(from variants: [AppData.Variant]?) -> GameProviderMetadata? {
        let publishers = uniqueNonEmpty(variants?.compactMap(\.publisherName) ?? [])
        guard !publishers.isEmpty else { return nil }
        return GameProviderMetadata(
            platform: "PC",
            releaseDate: nil,
            releaseYear: nil,
            developer: nil,
            publisher: publishers.joined(separator: ", "),
            genres: [],
            summary: nil
        )
    }

    private func mergedProviderMetadata(
        _ primary: GameProviderMetadata?,
        _ secondary: GameProviderMetadata?
    ) -> GameProviderMetadata? {
        guard var merged = primary else { return secondary }
        guard let secondary else { return merged }
        merged.platform = merged.platform ?? secondary.platform
        merged.releaseDate = merged.releaseDate ?? secondary.releaseDate
        merged.releaseYear = merged.releaseYear ?? secondary.releaseYear
        merged.developer = merged.developer ?? secondary.developer
        merged.publisher = merged.publisher ?? secondary.publisher
        merged.genres = uniqueNonEmpty(merged.genres + secondary.genres)
        merged.summary = merged.summary ?? secondary.summary
        return merged
    }

    private func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: - Helpers

    private func optimizeImageUrl(_ url: String, width: Int = 272) -> String? {
        guard !url.isEmpty else { return nil }
        if url.contains("img.nvidiagrid.net") {
            return "\(url.removingGFNWidthSuffix());w=\(width)"
        }
        return url
    }

    private func setGFNHeaders(on request: inout URLRequest, token: String) {
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/graphql", forHTTPHeaderField: "Content-Type")
        request.setValue("https://play.geforcenow.com", forHTTPHeaderField: "Origin")
        request.setValue("https://play.geforcenow.com/", forHTTPHeaderField: "Referer")
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(GamesClient.clientId, forHTTPHeaderField: "nv-client-id")
        request.setValue("NATIVE", forHTTPHeaderField: "nv-client-type")
        request.setValue(GamesClient.clientVersion, forHTTPHeaderField: "nv-client-version")
        request.setValue("NVIDIA-CLASSIC", forHTTPHeaderField: "nv-client-streamer")
        request.setValue("WINDOWS", forHTTPHeaderField: "nv-device-os")
        request.setValue("DESKTOP", forHTTPHeaderField: "nv-device-type")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-make")
        request.setValue("UNKNOWN", forHTTPHeaderField: "nv-device-model")
        request.setValue("CHROME", forHTTPHeaderField: "nv-browser-type")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
    }

    private func isNumericId(_ s: String?) -> Bool {
        guard let s else { return false }
        return s.allSatisfy { $0.isNumber } && !s.isEmpty
    }

    private func jsonString(_ obj: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }
}

// MARK: - Response Types

private struct ServerInfoResponse: Decodable {
    let requestStatus: RequestStatus?
    struct RequestStatus: Decodable { let serverId: String? }
}

private struct MetadataResponse: Decodable {
    let data: MetadataData?
    struct MetadataData: Decodable {
        let apps: AppsContainer
        struct AppsContainer: Decodable {
            let items: [AppData]
        }
    }
}

private struct PanelsResponse: Decodable {
    let data: PanelsData?
    let errors: [GQLError]?
    struct PanelsData: Decodable {
        let panels: [Panel]?
        struct Panel: Decodable {
            let name: String?
            let sections: [Section]?
            struct Section: Decodable {
                let items: [Item]?
                struct Item: Decodable {
                    let __typename: String
                    let app: AppData?
                }
            }
        }
    }
    struct GQLError: Decodable { let message: String }
}

private struct AppData: Decodable {
    let id: AnyCodableGameId?
    let title: String?
    let images: Images?
    let variants: [Variant]?

    struct Images: Decodable {
        let GAME_BOX_ART: String?
        let TV_BANNER: String?
        let HERO_IMAGE: String?
    }

    struct Variant: Decodable {
        let id: String?
        let appStore: String?
        let publisherName: String?
        let gfn: GFNMeta?
        struct GFNMeta: Decodable {
            let library: LibraryMeta?
            struct LibraryMeta: Decodable { let selected: Bool? }
        }
    }
}

private struct AnyCodableGameId: Decodable {
    let stringValue: String
    init(from decoder: Decoder) throws {
        if let int = try? Int(from: decoder) {
            stringValue = String(int)
        } else {
            stringValue = try String(from: decoder)
        }
    }
}

private struct WebsiteCatalogResponse: Decodable {
    let data: CatalogData

    struct CatalogData: Decodable {
        let apps: Apps
    }

    struct Apps: Decodable {
        let numberReturned: Int?
        let pageInfo: PageInfo
        let items: [WebsiteCatalogGame]
    }

    struct PageInfo: Decodable {
        let endCursor: String?
        let hasNextPage: Bool
    }
}

private struct WebsiteCatalogGame: Decodable {
    let id: String
    let title: String
    let sortName: String?
    let gfn: GFN?
    let variants: [Variant]?
    let images: Images?

    struct GFN: Decodable {
        let playType: String?
        let minimumMembershipTierLabel: String?
    }

    struct Variant: Decodable {
        let id: String?
        let appStore: String?
        let publisherName: String?
        let minimumSizeInBytes: Int?
    }

    struct Images: Decodable {
        let GAME_BOX_ART: String?
        let TV_BANNER: String?
        let HERO_IMAGE: String?
        let FEATURE_IMAGE: String?
    }

    func toGameInfo() -> GameInfo? {
        guard gfn?.playType != "INSTALL_TO_PLAY" else { return nil }
        let catalogVariants = variants?.compactMap { variant -> GameVariant? in
            guard let id = variant.id else { return nil }
            return GameVariant(
                id: id,
                appStore: normalizedStore(variant.appStore),
                appId: id,
                isOwned: false
            )
        } ?? []
        let fallbackId = catalogVariants.first?.id ?? id

        return GameInfo(
            id: fallbackId,
            title: title,
            boxArtUrl: images?.GAME_BOX_ART.flatMap { optimizedCatalogImageUrl($0) },
            heroBannerUrl: (images?.TV_BANNER ?? images?.HERO_IMAGE ?? images?.FEATURE_IMAGE).flatMap { optimizedCatalogImageUrl($0, width: 1920) },
            isInLibrary: false,
            variants: catalogVariants,
            providerMetadata: providerMetadata
        )
    }

    private var providerMetadata: GameProviderMetadata? {
        let publishers = Array(Set(variants?.compactMap(\.publisherName).filter { !$0.isEmpty } ?? [])).sorted()
        guard !publishers.isEmpty else { return nil }
        return GameProviderMetadata(
            platform: "PC",
            releaseDate: nil,
            releaseYear: nil,
            developer: nil,
            publisher: publishers.joined(separator: ", "),
            genres: [],
            summary: nil
        )
    }

    private func normalizedStore(_ store: String?) -> String {
        switch store?.lowercased() {
        case "steam": return "STEAM"
        case "epic", "epic games", "epic games store": return "EPIC_GAMES_STORE"
        case "gog": return "GOG"
        case "ea", "ea app", "origin": return "EA_APP"
        case "ubisoft", "ubisoft connect": return "UBISOFT"
        case "xbox", "microsoft", "microsoft store": return "XBOX"
        case "battle.net", "battlenet": return "BATTLENET"
        default: return store?.uppercased().replacingOccurrences(of: " ", with: "_") ?? "unknown"
        }
    }

    private func optimizedCatalogImageUrl(_ url: String, width: Int = 272) -> String? {
        guard !url.isEmpty else { return nil }
        if url.contains("img.nvidiagrid.net") {
            return "\(url.removingGFNWidthSuffix());w=\(width)"
        }
        return url
    }
}

private extension String {
    func removingGFNWidthSuffix() -> String {
        guard let range = range(of: ";w=") else { return self }
        return String(self[..<range.lowerBound])
    }
}

// MARK: - Errors

enum GamesError: Error, LocalizedError {
    case fetchFailed(String)
    var errorDescription: String? {
        if case .fetchFailed(let msg) = self { return "Games fetch failed: \(msg)" }
        return nil
    }
}
