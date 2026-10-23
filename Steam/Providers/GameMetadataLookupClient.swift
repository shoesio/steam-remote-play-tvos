import Foundation

/// GameDB stores IGDB platform identifiers on game records. Keep the common
/// identifiers local so metadata cards never expose an internal database ID.
nonisolated func resolvedGamePlatformName(_ rawValue: String?) -> String? {
    guard let rawValue else { return nil }
    let platformNames: [String: String] = [
        "3": "Linux",
        "4": "Nintendo 64",
        "5": "Nintendo Wii",
        "6": "Windows PC",
        "7": "PlayStation",
        "8": "PlayStation 2",
        "9": "PlayStation 3",
        "11": "Xbox",
        "12": "Xbox 360",
        "13": "DOS",
        "14": "macOS",
        "18": "Nintendo Entertainment System",
        "19": "Super Nintendo",
        "20": "Nintendo DS",
        "21": "Nintendo GameCube",
        "22": "Game Boy Color",
        "23": "Sega Dreamcast",
        "24": "Game Boy Advance",
        "29": "Sega Mega Drive / Genesis",
        "32": "Sega Saturn",
        "33": "Game Boy",
        "34": "Android",
        "35": "Sega Game Gear",
        "37": "Nintendo 3DS",
        "38": "PlayStation Portable",
        "39": "iOS",
        "41": "Nintendo Wii U",
        "46": "PlayStation Vita",
        "48": "PlayStation 4",
        "49": "Xbox One",
        "52": "Arcade",
        "64": "Sega Master System",
        "130": "Nintendo Switch",
        "137": "New Nintendo 3DS",
        "159": "Nintendo DSi",
        "165": "PlayStation VR",
        "167": "PlayStation 5",
        "169": "Xbox Series X|S",
        "170": "Google Stadia"
    ]

    let resolved = rawValue
        .split(separator: ",")
        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .compactMap { value -> String? in
            if let name = platformNames[value] { return name }
            // Preserve real platform names supplied by other providers, but do
            // not show an unresolved numeric database key to the user.
            return value.allSatisfy(\.isNumber) ? nil : value
        }

    return resolved.isEmpty ? nil : Array(NSOrderedSet(array: resolved))
        .compactMap { $0 as? String }
        .joined(separator: ", ")
}

struct GameMetadataLookupResult: Equatable, Codable, Sendable {
    var source: ArtworkSource
    var title: String?
    var platform: String? = nil
    var releaseDate: String?
    var releaseYear: Int?
    var developer: String?
    var publisher: String?
    var genres: [String]
    var summary: String?
    var externalIds: ExternalGameIds
    var heroArtworkUrl: String?
    var coverArtworkUrl: String? = nil
    var screenshotUrl: String?
}

struct GameMetadataArtworkCandidate: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var subtitle: String
    var source: ArtworkSource
    var role: ArtworkRole
    var url: String
    var metadata: GameMetadataLookupResult
}

actor GameMetadataLookupClient {
    private let urlSession: URLSession
    private let steamGridDB = SteamGridDBService()

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func lookup(
        title: String,
        igdbId: String?,
        gameDBId: String?,
        steamAppId: String?,
        steamGridDBAPIKey: String?
    ) async throws -> GameMetadataLookupResult? {
        if let steamGridDBAPIKey {
            let candidates = try? await steamGridDB.heroCandidates(
                title: title,
                steamAppID: steamAppId,
                apiKey: steamGridDBAPIKey
            )
            if let result = candidates?.first { return result.metadata }
        }
        if let gameDBResult = await lookupGameDB(gameDBId: gameDBId, igdbId: igdbId) {
            return gameDBResult
        }
        return nil
    }

    func artworkCandidates(
        title: String,
        igdbId: String?,
        gameDBId: String?,
        steamAppId: String?,
        steamGridDBAPIKey: String?
    ) async throws -> [GameMetadataArtworkCandidate] {
        var steamGridDBCandidates: [GameMetadataArtworkCandidate] = []
        if let steamGridDBAPIKey {
            // A temporary SteamGridDB failure should not hide the working local/provider choices.
            steamGridDBCandidates = (try? await steamGridDB.heroCandidates(
                title: title,
                steamAppID: steamAppId,
                apiKey: steamGridDBAPIKey
            )) ?? []
        }
        let gameDBCandidates = await lookupGameDBArtworkCandidates(
            title: title,
            gameDBId: gameDBId,
            igdbId: igdbId
        )
        // Reserve space for both sources instead of allowing a long GameDB result set
        // to consume the chooser's entire candidate budget.
        return uniqueArtworkCandidates(
            Array(steamGridDBCandidates.prefix(12)) + Array(gameDBCandidates.prefix(8))
        )
    }

    func coverArtworkCandidates(
        title: String,
        igdbId: String?,
        gameDBId: String?,
        steamAppId: String?,
        steamGridDBAPIKey: String?
    ) async throws -> [GameMetadataArtworkCandidate] {
        var steamGridDBCandidates: [GameMetadataArtworkCandidate] = []
        if let steamGridDBAPIKey {
            steamGridDBCandidates = (try? await steamGridDB.coverCandidates(
                title: title,
                steamAppID: steamAppId,
                apiKey: steamGridDBAPIKey
            )) ?? []
        }
        let gameDBCandidates = await lookupGameDBArtworkCandidates(
            title: title,
            gameDBId: gameDBId,
            igdbId: igdbId
        ).filter { $0.role == .tileCover || $0.role == .fallbackBlurredCover }
        return uniqueArtworkCandidates(steamGridDBCandidates + gameDBCandidates)
    }

    func metadataCandidates(title: String) async -> [GameMetadataLookupResult] {
        var candidates: [GameMetadataLookupResult] = []
        for key in await gameDBDetailKeys(title: title, gameDBId: nil, igdbId: nil) {
            guard let result = await gameDBLookupResult(key: key) else { continue }
            candidates.append(result)
        }
        var seen = Set<String>()
        return candidates.filter { result in
            let identity = result.externalIds.gameDBId
                ?? result.externalIds.igdbId
                ?? result.title
                ?? UUID().uuidString
            return seen.insert(identity).inserted
        }
    }

    private func lookupGameDB(gameDBId: String?, igdbId: String?) async -> GameMetadataLookupResult? {
        for key in await gameDBDetailKeys(title: nil, gameDBId: gameDBId, igdbId: igdbId) {
            if let result = await gameDBLookupResult(key: key) { return result }
        }
        return nil
    }

    private func gameDBLookupResult(key: String) async -> GameMetadataLookupResult? {
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://raw.githubusercontent.com/LizardByte/GameDB/gh-pages/games/\(encodedKey).json") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try gameDBLookupResult(from: data, key: key)
        } catch {
            return nil
        }
    }

    private func lookupGameDBArtworkCandidates(title: String, gameDBId: String?, igdbId: String?) async -> [GameMetadataArtworkCandidate] {
        var candidates: [GameMetadataArtworkCandidate] = []
        for key in await gameDBDetailKeys(title: title, gameDBId: gameDBId, igdbId: igdbId) {
            guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "https://raw.githubusercontent.com/LizardByte/GameDB/gh-pages/games/\(encodedKey).json") else {
                continue
            }
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let result = try gameDBLookupResult(from: data, key: key) else {
                    continue
                }
                candidates.append(contentsOf: gameDBArtworkCandidates(from: object, key: key, metadata: result))
            } catch {
                continue
            }
        }
        return uniqueArtworkCandidates(candidates)
    }


    private func gameDBDetailKeys(title: String?, gameDBId: String?, igdbId: String?) async -> [String] {
        var keys: [String] = []
        if let gameDBId = cleanGameDBKey(gameDBId) {
            keys.append(contentsOf: gameDBDetailKeys(from: gameDBId))
        }
        if let igdbId = igdbId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !igdbId.isEmpty {
            keys.append(igdbId)
        }
        if let title {
            keys.append(contentsOf: await gameDBTitleFallbackKeys(title: title))
        }
        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }

    private func gameDBDetailKeys(from value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let igdbId = firstCapture(in: trimmed, pattern: #"(?i)^igdb[_-]([0-9]{1,12})$"#) {
            return [igdbId]
        }
        if let numericId = firstCapture(in: trimmed, pattern: #"(?<![0-9])([0-9]{1,12})(?![0-9])"#) {
            return [numericId]
        }
        return [trimmed]
    }

    private func gameDBTitleFallbackKeys(title: String) async -> [String] {
        let normalized = normalizedTitle(title)
        guard normalized.count >= 2 else { return [] }
        let prefix = String(normalized.prefix(2))
        guard let url = URL(string: "https://raw.githubusercontent.com/LizardByte/GameDB/gh-pages/buckets/\(prefix).json") else {
            return []
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let bucket = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return []
            }
            let scored = bucket.compactMap { id, value -> (id: String, score: Double)? in
                guard let dictionary = value as? [String: Any],
                      let name = firstString(in: dictionary, keys: ["name", "title"]) else {
                    return nil
                }
                let candidate = normalizedTitle(name)
                let score: Double
                if candidate == normalized {
                    score = 1
                } else if candidate.contains(normalized) || normalized.contains(candidate) {
                    score = 0.82
                } else {
                    score = diceCoefficient(normalized, candidate)
                }
                guard score >= 0.74 else { return nil }
                return (id, score)
            }
            return scored
                .sorted { $0.score > $1.score }
                .prefix(4)
                .map(\.id)
        } catch {
            return []
        }
    }

    private func cleanGameDBKey(_ value: String?) -> String? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        value = value.replacingOccurrences(of: #"\.[A-Za-z0-9]{2,5}$"#, with: "", options: .regularExpression)
        if value.contains("/") {
            value = (value as NSString).lastPathComponent
                .replacingOccurrences(of: #"\.[A-Za-z0-9]{2,5}$"#, with: "", options: .regularExpression)
        }
        return value.isEmpty ? nil : value
    }

    private func gameDBLookupResult(from data: Data, key: String) throws -> GameMetadataLookupResult? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let title = firstString(in: object, keys: ["name", "title"])
        let summary = firstString(in: object, keys: ["summary", "description", "storyline", "overview"])
        let platform = resolvedGamePlatformName(
            names(from: firstValue(in: object, keys: ["platforms", "platform", "systems", "system"]))
                .joined(separator: ", ")
        )
        let releaseDate = gameDBReleaseDate(from: object)
        let releaseYear = gameDBReleaseYear(from: object, releaseDate: releaseDate)
        var externalIds = gameDBExternalIds(from: object, key: key)

        let developer = names(from: firstValue(in: object, keys: ["developers", "developer", "studios", "companies"]))
            .joined(separator: ", ")
        let publisher = names(from: firstValue(in: object, keys: ["publishers", "publisher"]))
            .joined(separator: ", ")
        let genres = uniqueStrings(
            names(from: firstValue(in: object, keys: ["genres", "genre"]))
                + names(from: firstValue(in: object, keys: ["tags", "themes", "keywords"]))
        )
        externalIds.gameDBId = externalIds.gameDBId ?? key

        let heroArtworkUrl = firstImageURL(in: object, keys: ["artworks", "artwork", "backgrounds", "background", "banners", "banner", "hero", "heroes"])
            ?? firstImageURL(in: object, keys: ["screenshots", "screenshot", "images"])
            ?? firstImageURL(in: object, keys: ["cover", "covers", "boxart", "poster"])
        let coverArtworkUrl = firstImageURL(in: object, keys: ["cover", "covers", "boxart", "poster"])
        let screenshotUrl = firstImageURL(in: object, keys: ["screenshots", "screenshot", "images"])

        return GameMetadataLookupResult(
            source: .gameDB,
            title: title,
            platform: platform,
            releaseDate: releaseDate,
            releaseYear: releaseYear,
            developer: developer.isEmpty ? nil : developer,
            publisher: publisher.isEmpty ? nil : publisher,
            genres: genres,
            summary: summary,
            externalIds: externalIds,
            heroArtworkUrl: heroArtworkUrl,
            coverArtworkUrl: coverArtworkUrl,
            screenshotUrl: screenshotUrl
        )
    }

    private func gameDBArtworkCandidates(
        from object: [String: Any],
        key: String,
        metadata: GameMetadataLookupResult
    ) -> [GameMetadataArtworkCandidate] {
        let title = metadata.title ?? key
        let heroURLs = imageURLs(in: object, keys: ["artworks", "artwork", "backgrounds", "background", "banners", "banner", "hero", "heroes"])
        let screenshotURLs = imageURLs(in: object, keys: ["screenshots", "screenshot", "images"])
        let coverURLs = imageURLs(in: object, keys: ["cover", "covers", "boxart", "poster"])

        var candidates: [GameMetadataArtworkCandidate] = []
        candidates.append(contentsOf: heroURLs.enumerated().map { index, url in
            GameMetadataArtworkCandidate(
                id: "gamedb:\(key):hero:\(index):\(url)",
                title: title,
                subtitle: "GameDB artwork",
                source: .gameDB,
                role: .heroBackground,
                url: url,
                metadata: metadata
            )
        })
        candidates.append(contentsOf: screenshotURLs.enumerated().map { index, url in
            GameMetadataArtworkCandidate(
                id: "gamedb:\(key):screenshot:\(index):\(url)",
                title: title,
                subtitle: "GameDB screenshot",
                source: .gameDB,
                role: .screenshot,
                url: url,
                metadata: metadata
            )
        })
        candidates.append(contentsOf: coverURLs.enumerated().map { index, url in
            GameMetadataArtworkCandidate(
                id: "gamedb:\(key):cover:\(index):\(url)",
                title: title,
                subtitle: "GameDB cover fallback",
                source: .gameDB,
                role: .tileCover,
                url: url,
                metadata: metadata
            )
        })
        if candidates.isEmpty, let hero = metadata.heroArtworkUrl {
            candidates.append(
                GameMetadataArtworkCandidate(
                    id: "gamedb:\(key):metadata-hero:\(hero)",
                    title: title,
                    subtitle: "GameDB metadata",
                    source: .gameDB,
                    role: .heroBackground,
                    url: hero,
                    metadata: metadata
                )
            )
        }
        return uniqueArtworkCandidates(candidates)
    }

    private func normalizedTitle(_ title: String) -> String {
        title
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"['’`]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(the|a|an|edition|standard|deluxe|ultimate|remastered|remake|game|rom|usa|europe)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func diceCoefficient(_ lhs: String, _ rhs: String) -> Double {
        let lhsPairs = bigrams(lhs)
        let rhsPairs = bigrams(rhs)
        guard !lhsPairs.isEmpty, !rhsPairs.isEmpty else { return lhs == rhs ? 1 : 0 }
        var rhsCounts = Dictionary(rhsPairs.map { ($0, 1) }, uniquingKeysWith: +)
        var intersection = 0
        for pair in lhsPairs {
            guard let count = rhsCounts[pair], count > 0 else { continue }
            intersection += 1
            rhsCounts[pair] = count - 1
        }
        return Double(2 * intersection) / Double(lhsPairs.count + rhsPairs.count)
    }

    private func bigrams(_ value: String) -> [String] {
        let scalars = Array(value.unicodeScalars)
        guard scalars.count > 1 else { return value.isEmpty ? [] : [value] }
        return (0..<(scalars.count - 1)).map { String(String.UnicodeScalarView([scalars[$0], scalars[$0 + 1]])) }
    }

    private func gameDBExternalIds(from object: [String: Any], key: String) -> ExternalGameIds {
        var ids = ExternalGameIds(gameDBId: key.allSatisfy(\.isNumber) ? "igdb_\(key)" : key)
        if let igdbId = igdbId(fromGameDBKey: key) {
            ids.igdbId = igdbId
        }
        if ids.igdbId == nil, key.allSatisfy(\.isNumber) {
            ids.igdbId = key
        }
        if ids.igdbId == nil, let objectId = firstInt(in: object, keys: ["id"]) {
            ids.igdbId = String(objectId)
            ids.gameDBId = ids.gameDBId ?? "igdb_\(objectId)"
        }

        for containerKey in ["external_ids", "externalIds", "external", "ids"] {
            guard let dictionary = object[containerKey] as? [String: Any] else { continue }
            ids.igdbId = ids.igdbId ?? firstString(in: dictionary, keys: ["igdb", "igdb_id", "igdbId"])
            ids.steamAppId = ids.steamAppId ?? firstString(in: dictionary, keys: ["steam", "steam_app_id", "steamAppId"])
            ids.xboxId = ids.xboxId ?? firstString(in: dictionary, keys: ["xbox", "xbox_id", "xboxId"])
            ids.epicId = ids.epicId ?? firstString(in: dictionary, keys: ["epic", "epic_id", "epicId", "egs"])
        }

        ids.igdbId = ids.igdbId ?? firstString(in: object, keys: ["igdb_id", "igdbId"])
        ids.steamAppId = ids.steamAppId ?? firstString(in: object, keys: ["steam_app_id", "steamAppId"])
        ids.xboxId = ids.xboxId ?? firstString(in: object, keys: ["xbox_id", "xboxId"])
        ids.epicId = ids.epicId ?? firstString(in: object, keys: ["epic_id", "epicId", "egs"])
        return ids
    }

    private func igdbId(fromGameDBKey key: String) -> String? {
        firstCapture(in: key, pattern: #"(?i)^igdb[_-]([0-9]{1,12})$"#)
    }

    private func gameDBReleaseDate(from object: [String: Any]) -> String? {
        if let timestamp = firstInt(in: object, keys: ["first_release_date", "firstReleaseDate"]) {
            return isoDateString(Date(timeIntervalSince1970: TimeInterval(timestamp)))
        }
        return firstString(in: object, keys: ["release_date", "releaseDate", "released", "date"])
    }

    private func isoDateString(_ date: Date) -> String {
        let components = Calendar(identifier: .gregorian)
            .dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return String(Calendar(identifier: .gregorian).component(.year, from: date))
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private func gameDBReleaseYear(from object: [String: Any], releaseDate: String?) -> Int? {
        if let year = firstInt(in: object, keys: ["year", "release_year", "releaseYear"]) {
            return year
        }
        guard let releaseDate else { return nil }
        return firstCapture(in: releaseDate, pattern: #"([12][0-9]{3})"#).flatMap(Int.init)
    }

    private func firstImageURL(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let url = imageURL(from: object[key]) {
                return url
            }
        }
        return nil
    }

    private func imageURLs(in object: [String: Any], keys: [String]) -> [String] {
        var urls: [String] = []
        for key in keys {
            urls.append(contentsOf: imageURLs(from: object[key]))
        }
        return uniqueStrings(urls)
    }

    private func imageURLs(from value: Any?) -> [String] {
        if let string = stringValue(value), let url = normalizedImageURL(string) {
            return [url]
        }
        if let dictionary = value as? [String: Any] {
            var urls: [String] = []
            for key in ["url", "image", "image_url", "imageUrl", "src"] {
                urls.append(contentsOf: imageURLs(from: dictionary[key]))
            }
            if let imageId = stringValue(dictionary["image_id"] ?? dictionary["imageId"]),
               let url = normalizedImageURL(imageId) {
                urls.append(url)
            }
            return uniqueStrings(urls)
        }
        if let array = value as? [Any] {
            return uniqueStrings(array.flatMap(imageURLs))
        }
        return []
    }

    private func imageURL(from value: Any?) -> String? {
        if let string = stringValue(value), let url = normalizedImageURL(string) {
            return url
        }
        if let dictionary = value as? [String: Any] {
            for key in ["url", "image", "image_url", "imageUrl", "src"] {
                if let url = imageURL(from: dictionary[key]) {
                    return url
                }
            }
            if let imageId = stringValue(dictionary["image_id"] ?? dictionary["imageId"]),
               let url = normalizedImageURL(imageId) {
                return url
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let url = imageURL(from: item) {
                    return url
                }
            }
        }
        return nil
    }

    private func normalizedImageURL(_ value: String) -> String? {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("//") {
            value = "https:\(value)"
        }
        if value.hasPrefix("http://") || value.hasPrefix("https://") {
            return value.replacingOccurrences(
                of: #"/t_[^/]+/"#,
                with: "/t_1080p/",
                options: .regularExpression
            )
        }
        if value.range(of: #"^[A-Za-z0-9_-]{5,}$"#, options: .regularExpression) != nil {
            return "https://images.igdb.com/igdb/image/upload/t_1080p/\(value).jpg"
        }
        return nil
    }

    private func firstValue(in object: [String: Any], keys: [String]) -> Any? {
        for key in keys {
            if let value = object[key] {
                return value
            }
        }
        return nil
    }

    private func firstString(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(object[key]), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func firstInt(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let int = intValue(object[key]) {
                return int
            }
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private func names(from value: Any?) -> [String] {
        if let string = stringValue(value) {
            return [string]
        }
        if let dictionary = value as? [String: Any] {
            if let name = firstString(in: dictionary, keys: ["name", "title", "value"]) {
                return [name]
            }
            return dictionary.values.flatMap(names)
        }
        if let array = value as? [Any] {
            return array.flatMap(names)
        }
        return []
    }

    private func uniqueStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private func uniqueArtworkCandidates(_ candidates: [GameMetadataArtworkCandidate]) -> [GameMetadataArtworkCandidate] {
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.url).inserted }
    }

    private func firstCapture(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return String(value[captureRange])
    }
}
