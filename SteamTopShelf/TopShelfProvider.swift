import Foundation
import CoreGraphics
import CoreText
import ImageIO
import TVServices
import UniformTypeIdentifiers

final class TopShelfProvider: TVTopShelfContentProvider {
    private let catalogue = SteamTopShelfCatalogue()

    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let games = await catalogue.loadGames()
        let items = games.map(Self.makeItem)
        guard !items.isEmpty else { return Self.fallbackContent() }
        return TVTopShelfCarouselContent(style: .details, items: items)
    }

    private static func makeItem(_ game: SteamTopShelfGame) -> TVTopShelfCarouselItem {
        let item = TVTopShelfCarouselItem(identifier: "steam-\(game.appID)")
        item.title = game.name
        item.contextTitle = game.comingSoon ? "Coming soon on Steam" : "Featured on Steam"
        item.summary = game.summary
        item.genre = game.genres.prefix(3).joined(separator: " · ")
        item.previewVideoURL = game.trailerURL
        item.mediaOptions = [.videoResolutionHD]
        if let releaseDate = game.releaseDate {
            item.namedAttributes = [TVTopShelfNamedAttribute(name: "Release", values: [releaseDate])]
        }
        item.setImageURL(game.heroURL, for: .screenScale1x)
        item.setImageURL(game.heroURL, for: .screenScale2x)
        if let launchURL = URL(string: "steam-tvos://launch?source=topshelf&app=\(game.appID)") {
            item.playAction = TVTopShelfAction(url: launchURL)
            item.displayAction = TVTopShelfAction(url: launchURL)
        }
        return item
    }

    private static func fallbackContent() -> TVTopShelfCarouselContent? {
        guard let heroURL = Bundle.main.url(forResource: "SteamTopShelfHero", withExtension: "png") else { return nil }
        let item = TVTopShelfCarouselItem(identifier: "steam-fallback")
        item.title = "Steam"
        item.contextTitle = "Open SteamOS"
        item.summary = "Your complete Steam library, streamed directly from the BC-250."
        item.setImageURL(heroURL, for: .screenScale1x)
        item.setImageURL(heroURL, for: .screenScale2x)
        if let launchURL = URL(string: "steam-tvos://launch?source=topshelf") {
            item.playAction = TVTopShelfAction(url: launchURL)
            item.displayAction = TVTopShelfAction(url: launchURL)
        }
        return TVTopShelfCarouselContent(style: .details, items: [item])
    }
}

private struct SteamTopShelfGame: Codable {
    let appID: Int
    let name: String
    let summary: String
    let genres: [String]
    let releaseDate: String?
    let comingSoon: Bool
    let heroURL: URL
    let trailerURL: URL
}

private actor SteamTopShelfCatalogue {
    private let maximumItems = 8
    private let maximumPoolItems = 32

    private var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: "group.com.josephhewes.SteamAppTV")
    }

    private var cacheLifetime: TimeInterval {
        let hours = sharedDefaults?.integer(forKey: "steam.topShelfRefreshHours") ?? 6
        return TimeInterval(max(hours, 1)) * 60 * 60
    }

    private var steamGridDBAPIKey: String {
        UserDefaults(suiteName: "group.com.josephhewes.SteamAppTV")?
            .string(forKey: "steam.steamGridDBAPIKey")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func loadGames() async -> [SteamTopShelfGame] {
        let hasSteamGridDBKey = !steamGridDBAPIKey.isEmpty
        let refreshGeneration = sharedDefaults?.integer(forKey: "steam.topShelfRefreshGeneration") ?? 0
        NSLog("[SteamTopShelf] SteamGridDB key available: %@", hasSteamGridDBKey.description)
        if let cache = readCache(),
           Date().timeIntervalSince(cache.savedAt) < cacheLifetime,
           cache.hadSteamGridDBKey == hasSteamGridDBKey,
           cache.refreshGeneration == refreshGeneration {
            return rotatedBatch(from: cache.games, generation: cache.rotationGeneration)
        }
        do {
            let sharedDefaults = UserDefaults(suiteName: "group.com.josephhewes.SteamAppTV")
            let cataloguePage = (sharedDefaults?.integer(forKey: "steam.topShelfCataloguePage") ?? 0) + 1
            let candidates = try await catalogueCandidates(start: cataloguePage * 75)
            var games = await qualifyingGames(from: candidates)
            if games.count < maximumItems {
                let existing = Set(candidates.map(\.id))
                let mainCandidates = try await catalogueCandidates(start: 0)
                    .filter { !existing.contains($0.id) }
                games.append(contentsOf: await qualifyingGames(from: mainCandidates))
            }
            let pool = Array(games.prefix(maximumPoolItems))
            if !pool.isEmpty {
                // A fresh installation begins on the second complete batch so
                // an explicit refresh visibly replaces the currently shown set.
                let generation = (readCache()?.rotationGeneration ?? 1) + 1
                writeCache(
                    games: pool,
                    rotationGeneration: generation,
                    hadSteamGridDBKey: hasSteamGridDBKey,
                    refreshGeneration: refreshGeneration
                )
                sharedDefaults?.set(cataloguePage, forKey: "steam.topShelfCataloguePage")
                NSLog("[SteamTopShelf] eligible catalogue pool: %d; rotation: %d", pool.count, generation)
                return rotatedBatch(from: pool, generation: generation)
            }
        } catch {
            // Keep the previous carousel when Steam is temporarily unavailable.
        }
        guard let cache = readCache() else { return [] }
        return rotatedBatch(from: cache.games, generation: cache.rotationGeneration)
    }

    private func qualifyingGames(from candidates: [SteamCandidate]) async -> [SteamTopShelfGame] {
        await withTaskGroup(of: (Int, SteamTopShelfGame?).self) { group in
            for (index, candidate) in candidates.prefix(100).enumerated() {
                group.addTask {
                    (index, try? await self.gameDetails(appID: candidate.id, fallbackHero: candidate.heroURL))
                }
            }
            var ordered: [(Int, SteamTopShelfGame)] = []
            for await (index, game) in group {
                if let game { ordered.append((index, game)) }
            }
            return ordered.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private func rotatedBatch(from games: [SteamTopShelfGame], generation: Int) -> [SteamTopShelfGame] {
        guard games.count > maximumItems else { return games }
        let start = (generation * maximumItems) % games.count
        return (0..<min(maximumItems, games.count)).map { games[(start + $0) % games.count] }
    }

    private func catalogueCandidates(start: Int) async throws -> [SteamCandidate] {
        // Use Steam's broad mainstream catalogue, then remove genuinely adult,
        // frightening, zombie and gory material using the store metadata.
        return try await searchTopSellers(start: start)
    }

    private func searchTopSellers(start: Int) async throws -> [SteamCandidate] {
        var components = URLComponents(string: "https://store.steampowered.com/search/results/")!
        components.queryItems = [
            URLQueryItem(name: "query", value: ""),
            URLQueryItem(name: "start", value: String(start)),
            URLQueryItem(name: "count", value: "100"),
            URLQueryItem(name: "sort_by", value: "_ASC"),
            URLQueryItem(name: "filter", value: "topsellers"),
            URLQueryItem(name: "infinite", value: "1"),
            URLQueryItem(name: "cc", value: "GB"),
            URLQueryItem(name: "l", value: "english")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogueError.badResponse }
        let html = try JSONDecoder().decode(SteamSearchFeed.self, from: data).resultsHTML
        let expression = try NSRegularExpression(pattern: #"data-ds-appid="(\d+)""#)
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let idRange = Range(match.range(at: 1), in: html),
                  let id = Int(html[idRange]) else { return nil }
            return SteamCandidate(id: id, largeCapsuleImage: nil, headerImage: nil, finalPrice: nil)
        }
    }

    private func featuredCandidates() async throws -> [SteamCandidate] {
        let url = URL(string: "https://store.steampowered.com/api/featuredcategories?cc=GB&l=english")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogueError.badResponse }
        let feed = try JSONDecoder().decode(SteamFeaturedFeed.self, from: data)
        let mixed = interleave(
            feed.topSellers?.items ?? [],
            feed.specials?.items ?? [],
            feed.comingSoon?.items ?? [],
            feed.newReleases?.items ?? []
        )
        var seen = Set<Int>()
        return mixed.filter {
            seen.insert($0.id).inserted && ($0.finalPrice == nil || $0.finalPrice! >= 1_999)
        }
    }

    private func gameDetails(appID: Int, fallbackHero _: URL?) async throws -> SteamTopShelfGame {
        var components = URLComponents(string: "https://store.steampowered.com/api/appdetails")!
        components.queryItems = [
            URLQueryItem(name: "appids", value: String(appID)),
            URLQueryItem(name: "cc", value: "GB"),
            URLQueryItem(name: "l", value: "english")
        ]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CatalogueError.badResponse }
        let result = try JSONDecoder().decode([String: SteamAppEnvelope].self, from: data)
        guard let details = result[String(appID)]?.data,
              details.isLivingRoomSafeEstablishedTitle,
              let trailer = details.movies?.first(where: { $0.highlight == true }) ?? details.movies?.first,
              let trailerURL = trailer.hlsH264 else {
            throw CatalogueError.missingMedia
        }
        // Require Steam's official branded 2x capsule. Games without that exact
        // asset are excluded instead of falling back to soft or logo-free art.
        let selectedArtwork = try await highResolutionBrandedArtwork(appID: appID)
        let heroURL = selectedArtwork
        NSLog("[SteamTopShelf] artwork app=%d source=Steam-main-capsule-2x", appID)
        return SteamTopShelfGame(
            appID: appID,
            name: details.name,
            summary: details.shortDescription.strippingHTML,
            genres: details.genres?.map(\.description) ?? [],
            releaseDate: details.releaseDate?.date,
            comingSoon: details.releaseDate?.comingSoon ?? false,
            heroURL: heroURL,
            trailerURL: trailerURL
        )
    }

    private func steamGridDBBrandedCard(appID: Int) async throws -> URL {
        let key = steamGridDBAPIKey
        guard !key.isEmpty else { throw CatalogueError.missingMedia }
        var components = URLComponents(string: "https://www.steamgriddb.com/api/v2/grids/steam/\(appID)")!
        components.queryItems = [
            URLQueryItem(name: "types", value: "static"),
            URLQueryItem(name: "dimensions", value: "920x430"),
            URLQueryItem(name: "styles", value: "alternate,material,white_logo"),
            URLQueryItem(name: "nsfw", value: "false"),
            URLQueryItem(name: "humor", value: "false"),
            URLQueryItem(name: "epilepsy", value: "false")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CatalogueError.missingMedia }
        let decoded = try? JSONDecoder().decode(SteamGridDBHeroResponse.self, from: data)
        UserDefaults(suiteName: "group.com.josephhewes.SteamAppTV")?.set(
            "HTTP \(http.statusCode), \(decoded?.data.count ?? 0) branded cards for app \(appID)",
            forKey: "steam.steamGridDBLastResult"
        )
        NSLog("[SteamTopShelf] SteamGridDB app=%d status=%d brandedCards=%d", appID, http.statusCode, decoded?.data.count ?? 0)
        guard (200..<300).contains(http.statusCode),
              let image = decoded?.data.first,
              let url = URL(string: image.url) else { throw CatalogueError.missingMedia }
        return url
    }

    private func highResolutionBrandedArtwork(appID: Int) async throws -> URL {
        let payload = SteamBrowseInput(
            ids: [.init(appid: appID)],
            context: .init(language: "english", countryCode: "GB", steamRealm: 1),
            dataRequest: .init(includeAssets: true)
        )
        let inputData = try JSONEncoder().encode(payload)
        var components = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/")!
        components.queryItems = [URLQueryItem(name: "input_json", value: String(decoding: inputData, as: UTF8.self))]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let assets = try JSONDecoder().decode(SteamBrowseEnvelope.self, from: data).response.storeItems.first?.assets,
              let filename = assets.mainCapsule2x else {
            throw CatalogueError.missingMedia
        }
        let relative = assets.assetURLFormat.replacingOccurrences(of: "${FILENAME}", with: filename)
        guard let url = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/\(relative)") else {
            throw CatalogueError.missingMedia
        }
        return url
    }

    private func composedHero(appID: Int, name: String, sourceURL: URL) async throws -> URL {
        guard let sharedDirectory = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.josephhewes.SteamAppTV"
        ) else {
            throw CatalogueError.missingMedia
        }
        let destinationURL = sharedDirectory.appendingPathComponent("steam-topshelf-composite-v1-\(appID).jpg")
        if FileManager.default.fileExists(atPath: destinationURL.path) { return destinationURL }

        let (data, response) = try await URLSession.shared.data(from: sourceURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let colourSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: 1920,
                height: 1080,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colourSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { throw CatalogueError.missingMedia }

        let scale = max(1920.0 / CGFloat(image.width), 1080.0 / CGFloat(image.height))
        let imageWidth = CGFloat(image.width) * scale
        let imageHeight = CGFloat(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (1920 - imageWidth) / 2, y: (1080 - imageHeight) / 2, width: imageWidth, height: imageHeight))

        let colours = [
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.82),
            CGColor(red: 0, green: 0, blue: 0, alpha: 0.0)
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: colourSpace, colors: colours, locations: [0, 1]) {
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 520), options: [])
        }

        var fontSize: CGFloat = 88
        var line = makeTitleLine(name, fontSize: fontSize)
        while CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) > 1500, fontSize > 52 {
            fontSize -= 4
            line = makeTitleLine(name, fontSize: fontSize)
        }
        context.setShadow(offset: CGSize(width: 0, height: -3), blur: 14, color: CGColor(gray: 0, alpha: 0.8))
        context.textPosition = CGPoint(x: 110, y: 105)
        CTLineDraw(line, context)

        guard let rendered = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else { throw CatalogueError.missingMedia }
        CGImageDestinationAddImage(destination, rendered, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CatalogueError.missingMedia }
        return destinationURL
    }

    private func makeTitleLine(_ title: String, fontSize: CGFloat) -> CTLine {
        let font = CTFontCreateWithName("SFProDisplay-Semibold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)
        ]
        return CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, title as CFString, attributes as CFDictionary))
    }

    private func interleave(_ lists: [SteamCandidate]...) -> [SteamCandidate] {
        var result: [SteamCandidate] = []
        let count = lists.map(\.count).max() ?? 0
        for index in 0..<count {
            for list in lists where list.indices.contains(index) {
                result.append(list[index])
            }
        }
        return result
    }

    private struct Cache: Codable {
        let savedAt: Date
        let games: [SteamTopShelfGame]
        let rotationGeneration: Int
        let hadSteamGridDBKey: Bool
        let refreshGeneration: Int
    }

    private var cacheURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("steam-topshelf-steam-aaa-v17.json")
    }

    private func readCache() -> Cache? {
        guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private func writeCache(
        games: [SteamTopShelfGame],
        rotationGeneration: Int,
        hadSteamGridDBKey: Bool,
        refreshGeneration: Int
    ) {
        guard let cacheURL,
              let data = try? JSONEncoder().encode(
                Cache(
                    savedAt: Date(),
                    games: games,
                    rotationGeneration: rotationGeneration,
                    hadSteamGridDBKey: hadSteamGridDBKey,
                    refreshGeneration: refreshGeneration
                )
              ) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

private struct SteamFeaturedFeed: Decodable {
    let topSellers: SteamCategory?
    let comingSoon: SteamCategory?
    let newReleases: SteamCategory?
    let specials: SteamCategory?

    enum CodingKeys: String, CodingKey {
        case topSellers = "top_sellers"
        case comingSoon = "coming_soon"
        case newReleases = "new_releases"
        case specials
    }
}

private struct SteamSearchFeed: Decodable {
    let resultsHTML: String
    enum CodingKeys: String, CodingKey { case resultsHTML = "results_html" }
}

private struct SteamGridDBHeroResponse: Decodable {
    struct Image: Decodable {
        let url: String
        let width: Int
        let height: Int
    }
    let success: Bool
    let data: [Image]
}

private struct SteamCategory: Decodable { let items: [SteamCandidate] }

private struct SteamCandidate: Decodable {
    let id: Int
    let largeCapsuleImage: URL?
    let headerImage: URL?
    let finalPrice: Int?
    var heroURL: URL? { largeCapsuleImage ?? headerImage }

    enum CodingKeys: String, CodingKey {
        case id
        case largeCapsuleImage = "large_capsule_image"
        case headerImage = "header_image"
        case finalPrice = "final_price"
    }
}

private struct SteamAppEnvelope: Decodable { let data: SteamAppDetails? }

private struct SteamAppDetails: Decodable {
    let type: String?
    let name: String
    let shortDescription: String
    let headerImage: URL?
    let backgroundRaw: URL?
    let genres: [SteamGenre]?
    let movies: [SteamMovie]?
    let screenshots: [SteamScreenshot]?
    let developers: [String]?
    let publishers: [String]?
    let recommendations: SteamRecommendations?
    let releaseDate: SteamReleaseDate?
    let requiredAge: FlexibleInt?
    let contentDescriptors: SteamContentDescriptors?

    enum CodingKeys: String, CodingKey {
        case type, name, genres, movies, screenshots, developers, publishers, recommendations
        case shortDescription = "short_description"
        case headerImage = "header_image"
        case backgroundRaw = "background_raw"
        case releaseDate = "release_date"
        case requiredAge = "required_age"
        case contentDescriptors = "content_descriptors"
    }

    var hasMajorPublisher: Bool {
        let names = (publishers ?? []) + (developers ?? [])
        let majorNames = [
            "electronic arts", "ea sports", "ubisoft", "bethesda", "xbox game studios",
            "playstation publishing", "sony interactive", "activision", "blizzard",
            "2k", "rockstar", "take-two", "sega", "bandai namco", "capcom",
            "square enix", "konami", "warner bros", "wb games", "cd projekt",
            "valve", "koei tecmo", "thq nordic", "plaion", "deep silver",
            "focus entertainment", "fromsoftware", "larian studios", "io interactive",
            "nacon", "505 games", "remedy entertainment", "aspyr", "bit reactor"
        ]
        return names.contains { name in
            let lower = name.lowercased()
            return majorNames.contains { lower.contains($0) }
        }
    }

    var isEstablishedTitle: Bool {
        type == "game" && hasMajorPublisher
    }

    var isLivingRoomSafeEstablishedTitle: Bool {
        guard isEstablishedTitle,
              (requiredAge?.value ?? 0) <= 12 else { return false }
        let text = ([name, shortDescription] + (genres?.map(\.description) ?? []))
            .joined(separator: " ").lowercased()
        let excluded = [
            "adult", "blood", "gore", "horror", "mature", "nudity", "sexual",
            "slasher", "terror", "zombie"
        ]
        return !excluded.contains { text.contains($0) }
    }
}

private struct SteamContentDescriptors: Decodable { let ids: [Int]? }

private struct FlexibleInt: Decodable {
    let value: Int
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int.self) { value = integer }
        else if let string = try? container.decode(String.self), let integer = Int(string) { value = integer }
        else { value = 0 }
    }
}

private struct SteamGenre: Decodable { let description: String }

private struct SteamScreenshot: Decodable {
    let pathFull: URL?
    enum CodingKeys: String, CodingKey { case pathFull = "path_full" }
}

private struct SteamRecommendations: Decodable { let total: Int }

private struct SteamBrowseInput: Encodable {
    struct ID: Encodable { let appid: Int }
    struct Context: Encodable {
        let language: String
        let countryCode: String
        let steamRealm: Int
        enum CodingKeys: String, CodingKey {
            case language
            case countryCode = "country_code"
            case steamRealm = "steam_realm"
        }
    }
    struct DataRequest: Encodable {
        let includeAssets: Bool
        enum CodingKeys: String, CodingKey { case includeAssets = "include_assets" }
    }
    let ids: [ID]
    let context: Context
    let dataRequest: DataRequest
    enum CodingKeys: String, CodingKey {
        case ids, context
        case dataRequest = "data_request"
    }
}

private struct SteamBrowseEnvelope: Decodable {
    struct Response: Decodable {
        let storeItems: [Item]
        enum CodingKeys: String, CodingKey { case storeItems = "store_items" }
    }
    struct Item: Decodable { let assets: Assets? }
    struct Assets: Decodable {
        let assetURLFormat: String
        let mainCapsule: String?
        let mainCapsule2x: String?
        enum CodingKeys: String, CodingKey {
            case assetURLFormat = "asset_url_format"
            case mainCapsule = "main_capsule"
            case mainCapsule2x = "main_capsule_2x"
        }
    }
    let response: Response
}

private struct SteamMovie: Decodable {
    let highlight: Bool?
    let hlsH264: URL?
    enum CodingKeys: String, CodingKey {
        case highlight
        case hlsH264 = "hls_h264"
    }
}

private struct SteamReleaseDate: Decodable {
    let comingSoon: Bool
    let date: String
    enum CodingKeys: String, CodingKey {
        case comingSoon = "coming_soon"
        case date
    }
}

private enum CatalogueError: Error { case badResponse, missingMedia }

private extension String {
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
