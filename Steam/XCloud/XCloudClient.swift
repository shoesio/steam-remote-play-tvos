import Foundation

actor XCloudClient {
    private let host: String
    private let token: String
    private let supplementaryCatalog: (host: String, token: String)?
    private static let newOnXCloudSIGLID = "06323672-b8c8-43cc-b0de-32d5a9834749"
    private static let mostPopularSIGLID = "6a589fa0-d493-472b-8e20-3813699d7056"

    init(credentials: XCloudCredentials) {
        host = credentials.streamHost
        token = credentials.gsToken
        if let f2pHost = credentials.f2pHost, let f2pToken = credentials.f2pToken {
            supplementaryCatalog = (f2pHost, f2pToken)
        } else {
            supplementaryCatalog = nil
        }
    }

    func games() async throws -> [XCloudGame] {
        var catalogs: [(label: String, data: Data)] = []
        let (primaryData, _) = try await request(path: "/v2/titles")
        catalogs.append(("Game Pass", primaryData))

        if let supplementaryCatalog {
            do {
                let client = XCloudClient(host: supplementaryCatalog.host, token: supplementaryCatalog.token)
                let (data, _) = try await client.request(path: "/v2/titles")
                catalogs.append(("Free-to-play", data))
            } catch {
                print("[XCloud] supplementary catalog failed: \(error.localizedDescription)")
            }
        }

        var byID: [String: XCloudGame] = [:]
        for catalog in catalogs {
            let parsed = try parseGames(catalog.data)
            print("[XCloud] \(catalog.label) catalog raw=\(parsed.rawCount) parsed=\(parsed.games.count) host=\(host)")
            for game in parsed.games { byID[game.id] = game }
        }

        if byID.isEmpty {
            // MRU is a useful compatibility fallback when an account receives an empty full-library envelope.
            if let (mruData, _) = try? await request(path: "/v2/titles/mru?mr=50") {
                let parsed = try parseGames(mruData)
                print("[XCloud] MRU fallback raw=\(parsed.rawCount) parsed=\(parsed.games.count)")
                for game in parsed.games { byID[game.id] = game }
            }
        }

        let entitled = byID.values.filter(\.hasEntitlement)
        let hydrated = await hydrateArtwork(for: entitled)
        return hydrated.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func homePlaylists(from games: [XCloudGame]) async -> XCloudHomePlaylists {
        async let newIDs = fetchSIGLProductIDs(Self.newOnXCloudSIGLID)
        async let popularIDs = fetchSIGLProductIDs(Self.mostPopularSIGLID)
        let (newProductIDs, popularProductIDs) = await (newIDs, popularIDs)
        return XCloudHomePlaylists(
            newOnXCloud: gamesOrdered(byProductIDs: newProductIDs, from: games),
            mostPopular: gamesOrdered(byProductIDs: popularProductIDs, from: games)
        )
    }

    private init(host: String, token: String) {
        self.host = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.token = token
        supplementaryCatalog = nil
    }

    private func parseGames(_ data: Data) throws -> (games: [XCloudGame], rawCount: Int) {
        let root = try object(data)
        let rawResults = root["results"] as? [Any]
            ?? (root["titles"] as? [Any])
            ?? ((root["value"] as? [String: Any])?["results"] as? [Any])
            ?? []
        let games = rawResults.compactMap { value -> XCloudGame? in
            guard let raw = value as? [String: Any],
                  let titleID = string(raw["titleId"] ?? raw["titleID"] ?? raw["id"]) else { return nil }
            let details = detailsDictionary(raw["details"])
            let productID = string(details["productId"] ?? details["productID"] ?? raw["productId"]) ?? ""
            let rawName = string(details["name"] ?? details["title"] ?? raw["name"] ?? raw["title"])
            let name = XCloudTitleFormatter.displayTitle(rawName ?? titleID)
            let inputs = details["supportedInputTypes"] as? [String] ?? []
            let entitlement = bool(details["hasEntitlement"] ?? raw["hasEntitlement"])
            return XCloudGame(
                id: titleID,
                productID: productID,
                title: name.isEmpty ? XCloudTitleFormatter.displayTitle(titleID) : name,
                supportsController: inputs.isEmpty || inputs.contains { $0.localizedCaseInsensitiveContains("controller") },
                hasEntitlement: entitlement,
                boxArtURL: nil,
                heroArtURL: nil,
                providerMetadata: nil
            )
        }
        return (games, rawResults.count)
    }

    private func detailsDictionary(_ value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let text = value as? String,
           let data = text.data(using: .utf8),
           let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return dictionary
        }
        return [:]
    }

    private func hydrateArtwork(for games: [XCloudGame]) async -> [XCloudGame] {
        let productIDs = Array(Set(games.map(\.productID).filter { !$0.isEmpty }))
        guard !productIDs.isEmpty else { return games }
        var artwork: [String: (title: String?, poster: String?, hero: String?, metadata: GameProviderMetadata?)] = [:]

        for start in stride(from: 0, to: productIDs.count, by: 100) {
            let batch = Array(productIDs[start..<min(start + 100, productIDs.count)])
            do {
                var components = URLComponents(string: "https://catalog.gamepass.com/v3/products")!
                components.queryItems = [
                    URLQueryItem(name: "market", value: Locale.current.region?.identifier ?? "US"),
                    URLQueryItem(name: "language", value: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")),
                    URLQueryItem(name: "hydration", value: "RemoteHighSapphire0")
                ]
                var request = URLRequest(url: components.url!)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue("0.0", forHTTPHeaderField: "ms-cv")
                request.setValue("Xbox Cloud Gaming Web", forHTTPHeaderField: "calling-app-name")
                request.setValue("21.0.0", forHTTPHeaderField: "calling-app-version")
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONSerialization.data(withJSONObject: ["Products": batch])
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                for product in productDictionaries(root["Products"]) {
                    guard let productID = string(product["ProductId"] ?? product["StoreId"]) else { continue }
                    artwork[productID] = productPresentation(from: product)
                }
            } catch {
                print("[XCloud] artwork hydration failed: \(error.localizedDescription)")
            }
        }

        return games.map { game in
            guard let images = artwork[game.productID] else { return game }
            return XCloudGame(
                id: game.id,
                productID: game.productID,
                title: images.title.map(XCloudTitleFormatter.displayTitle).flatMap { $0.isEmpty ? nil : $0 } ?? game.title,
                supportsController: game.supportsController,
                hasEntitlement: game.hasEntitlement,
                boxArtURL: images.poster,
                heroArtURL: images.hero,
                providerMetadata: images.metadata
            )
        }
    }

    private func fetchSIGLProductIDs(_ id: String) async -> [String] {
        do {
            var components = URLComponents(string: "https://catalog.gamepass.com/sigls/v2")!
            components.queryItems = [
                URLQueryItem(name: "id", value: id),
                URLQueryItem(name: "language", value: Locale.current.identifier.replacingOccurrences(of: "_", with: "-")),
                URLQueryItem(name: "market", value: Locale.current.region?.identifier ?? "US")
            ]
            guard let url = components.url else { return [] }
            var request = URLRequest(url: url)
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                return []
            }
            return items.dropFirst().compactMap { string($0["id"] ?? $0["productId"] ?? $0["ProductId"]) }
        } catch {
            print("[XCloud] SIGL playlist \(id) failed: \(error.localizedDescription)")
            return []
        }
    }

    private func gamesOrdered(byProductIDs productIDs: [String], from games: [XCloudGame]) -> [XCloudGame] {
        guard !productIDs.isEmpty else { return [] }
        var gamesByProductID: [String: XCloudGame] = [:]
        for game in games where !game.productID.isEmpty && gamesByProductID[game.productID.uppercased()] == nil {
            gamesByProductID[game.productID.uppercased()] = game
        }
        var seen = Set<String>()
        return productIDs.compactMap { productID in
            guard seen.insert(productID.uppercased()).inserted else { return nil }
            return gamesByProductID[productID.uppercased()]
        }
    }

    private func productDictionaries(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [[String: Any]] { return array }
        if let dictionary = value as? [String: Any] {
            return dictionary.compactMap { key, raw in
                guard var product = raw as? [String: Any] else { return nil }
                if product["ProductId"] == nil { product["ProductId"] = key }
                return product
            }
        }
        return []
    }

    private func productPresentation(from product: [String: Any]) -> (title: String?, poster: String?, hero: String?, metadata: GameProviderMetadata?) {
        func direct(_ key: String) -> String? {
            guard let image = product[key] as? [String: Any] else { return nil }
            return normalizedArtworkURL(string(image["URL"] ?? image["Url"] ?? image["Uri"]))
        }
        var poster = direct("Image_Poster") ?? direct("Image_Tile")
        var hero = direct("Image_Hero")
        let localized = product["LocalizedProperties"] as? [[String: Any]] ?? []
        let localizedTitle = localized.compactMap {
            string($0["ProductTitle"] ?? $0["ProductDisplayName"] ?? $0["ShortTitle"] ?? $0["Title"])
        }.first
        let productTitle = localizedTitle ?? string(product["ProductTitle"] ?? product["Title"] ?? product["Name"])
        let publisher = localized.compactMap { string($0["PublisherName"]) }.first
            ?? string(product["PublisherName"] ?? product["Publisher"])
        let developer = localized.compactMap { string($0["DeveloperName"]) }.first
            ?? string(product["DeveloperName"] ?? product["Developer"])
        let summary = localized.compactMap {
            string($0["ShortDescription"] ?? $0["ProductDescription"] ?? $0["Description"])
        }.first
        let properties = product["Properties"] as? [String: Any]
        let genres = stringArray(properties?["Categories"] ?? product["Categories"] ?? product["Genres"])
        let marketProperties = product["MarketProperties"] as? [[String: Any]] ?? []
        let releaseDate = marketProperties.compactMap {
            string($0["OriginalReleaseDate"] ?? $0["ReleaseDate"])
        }.first ?? string(product["OriginalReleaseDate"] ?? product["ReleaseDate"])
        let releaseYear = releaseDate.flatMap { date in
            date.range(of: #"[12][0-9]{3}"#, options: .regularExpression)
                .flatMap { Int(date[$0]) }
        }
        let images = localized.flatMap { $0["Images"] as? [[String: Any]] ?? [] }
        for image in images {
            let purpose = (string(image["ImagePurpose"]) ?? "").lowercased()
            let url = normalizedArtworkURL(string(image["Uri"] ?? image["URL"] ?? image["Url"]))
            guard let url else { continue }
            if hero == nil, purpose.contains("hero") || purpose.contains("background") { hero = url }
            if poster == nil, purpose.contains("poster") || purpose.contains("box") || purpose.contains("tile") { poster = url }
        }
        let metadata = GameProviderMetadata(
            platform: "Xbox Cloud Gaming",
            releaseDate: releaseDate,
            releaseYear: releaseYear,
            developer: developer,
            publisher: publisher,
            genres: genres,
            summary: summary
        )
        return (productTitle, poster, hero ?? images.compactMap { normalizedArtworkURL(string($0["Uri"])) }.first, metadata)
    }

    private func stringArray(_ value: Any?) -> [String] {
        if let values = value as? [String] { return values.filter { !$0.isEmpty } }
        if let values = value as? [[String: Any]] {
            return values.compactMap { string($0["Name"] ?? $0["name"] ?? $0["Value"] ?? $0["value"]) }
        }
        if let value = string(value), !value.isEmpty { return [value] }
        return []
    }

    private func normalizedArtworkURL(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value.hasPrefix("//") ? "https:\(value)" : value
    }

    private func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "1" || value.lowercased() == "true" }
        return false
    }

    func start(titleID: String) async throws -> XCloudSession {
        let body: [String: Any] = [
            "clientSessionId": "",
            "titleId": titleID,
            "systemUpdateGroup": "",
            "settings": [
                "nanoVersion": "V3;WebrtcTransport.dll",
                "enableOptionalDataCollection": false,
                "enableTextToSpeech": false,
                "highContrast": 0,
                "locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
                "useIceConnection": false,
                "timezoneOffsetMinutes": TimeZone.current.secondsFromGMT() / -60,
                "sdkType": "web",
                "osName": "windows"
            ],
            "serverId": "",
            "fallbackRegionNames": []
        ]
        let (data, _) = try await request(path: "/v5/sessions/cloud/play", method: "POST", json: body)
        let json = try object(data)
        guard let path = json["sessionPath"] as? String else {
            throw XCloudError.invalidResponse("Missing session path.")
        }
        return XCloudSession(path: path, titleID: titleID)
    }

    func waitUntilReady(_ session: XCloudSession, timeout: TimeInterval = 300) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let (data, _) = try await request(path: "\(session.path)/state")
            let json = try object(data)
            let state = (json["state"] as? String ?? "").lowercased()
            switch state {
            case "readytoconnect", "provisioned": return state
            case "failed", "error":
                throw XCloudError.invalidResponse("Session provisioning failed: \(json)")
            default:
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw XCloudError.timedOut("waiting for a cloud console")
    }

    func connect(_ session: XCloudSession, longPlayToken: String) async throws {
        _ = try await request(path: "\(session.path)/connect", method: "POST", json: ["userToken": longPlayToken])
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let (data, _) = try await request(path: "\(session.path)/state")
            let state = ((try object(data))["state"] as? String ?? "").lowercased()
            if state == "provisioned" { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw XCloudError.timedOut("provisioning the stream")
    }

    func exchangeSDP(_ session: XCloudSession, offer: String) async throws -> String {
        let configuration: [String: Any] = [
            "chatConfiguration": [
                "bytesPerSample": 2,
                "expectedClipDurationMs": 20,
                "format": ["codec": "opus", "container": "webm"],
                "numChannels": 1,
                "sampleFrequencyHz": 24000
            ],
            "chat": ["minVersion": 1, "maxVersion": 1],
            "control": ["minVersion": 1, "maxVersion": 3],
            "input": ["minVersion": 1, "maxVersion": 9],
            "message": ["minVersion": 1, "maxVersion": 1],
            "reliableinput": ["minVersion": 9, "maxVersion": 9],
            "unreliableinput": ["minVersion": 9, "maxVersion": 9]
        ]
        let body: [String: Any] = ["messageType": "offer", "sdp": offer, "requestId": "1", "configuration": configuration]
        let (posted, _) = try await request(path: "\(session.path)/sdp", method: "POST", json: body)
        if let answer = extractSDP(from: posted) { return answer }
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(500))
            let (data, response) = try await request(path: "\(session.path)/sdp", allowNoContent: true)
            if response.statusCode != 204, let answer = extractSDP(from: data) { return answer }
        }
        throw XCloudError.timedOut("negotiating video")
    }

    func exchangeICE(_ session: XCloudSession, candidates: [XCloudICECandidate]) async throws -> [XCloudICECandidate] {
        let encoded: [String] = try candidates.map { candidate in
            let candidateText = candidate.candidate.hasPrefix("a=")
                ? String(candidate.candidate.dropFirst(2))
                : candidate.candidate
            var wire: [String: Any] = [
                "candidate": candidateText,
                "sdpMLineIndex": candidate.mLineIndex,
                "sdpMid": candidate.mid
            ]
            if let usernameFragment = candidate.usernameFragment { wire["usernameFragment"] = usernameFragment }
            let data = try JSONSerialization.data(withJSONObject: wire)
            return String(data: data, encoding: .utf8)!
        }
        _ = try await request(path: "\(session.path)/ice", method: "POST", json: ["candidates": encoded])
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(1))
            let (data, response) = try await request(path: "\(session.path)/ice", allowNoContent: true)
            if response.statusCode == 204 { continue }
            if let candidates = extractICE(from: data), !candidates.isEmpty { return candidates }
        }
        return []
    }

    func keepalive(_ session: XCloudSession) async throws {
        _ = try await request(path: "\(session.path)/keepalive", method: "POST", json: [:])
    }

    func stop(_ session: XCloudSession) async {
        _ = try? await request(path: session.path, method: "DELETE")
    }

    private func request(
        path: String,
        method: String = "GET",
        json: [String: Any]? = nil,
        allowNoContent: Bool = false
    ) async throws -> (Data, HTTPURLResponse) {
        guard let url = endpointURL(path: path) else { throw XCloudError.invalidResponse("Invalid xCloud URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("XboxComBrowser", forHTTPHeaderField: "X-Gssv-Client")
        request.setValue(Self.deviceInfo, forHTTPHeaderField: "X-MS-Device-Info")
        if let json { request.httpBody = try JSONSerialization.data(withJSONObject: json) }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw XCloudError.invalidResponse("No HTTP response.") }
        if allowNoContent, http.statusCode == 204 { return (data, http) }
        guard (200...299).contains(http.statusCode) else {
            throw XCloudError.server(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http)
    }

    private func endpointURL(path: String) -> URL? {
        if path.hasPrefix("https://") || path.hasPrefix("http://") {
            return URL(string: path)
        }
        let normalizedHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: normalizedHost + normalizedPath)
    }

    private func extractSDP(from data: Data) -> String? {
        guard !data.isEmpty, let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return recursiveSDP(value)
    }

    private func recursiveSDP(_ value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let sdp = dict["sdp"] as? String { return sdp }
            if let nested = dict["exchangeResponse"] { return recursiveSDP(nested) }
        }
        if let text = value as? String, let data = text.data(using: .utf8),
           let nested = try? JSONSerialization.jsonObject(with: data) { return recursiveSDP(nested) }
        return nil
    }

    private func extractICE(from data: Data) -> [XCloudICECandidate]? {
        guard !data.isEmpty, let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return recursiveICE(value)
    }

    private func recursiveICE(_ value: Any) -> [XCloudICECandidate]? {
        if let array = value as? [Any] {
            return array.compactMap { item in
                if let text = item as? String, let data = text.data(using: .utf8),
                   let decoded = try? JSONSerialization.jsonObject(with: data) { return recursiveICE(decoded)?.first }
                guard let dict = item as? [String: Any], let candidate = dict["candidate"] as? String else { return nil }
                return XCloudICECandidate(
                    candidate: candidate,
                    mLineIndex: (dict["sdpMLineIndex"] as? NSNumber)?.intValue ?? 0,
                    mid: dict["sdpMid"] as? String ?? "0",
                    usernameFragment: dict["usernameFragment"] as? String
                )
            }
        }
        if let dict = value as? [String: Any] {
            for key in ["exchangeResponse", "iceCandidates", "candidates"] {
                if let nested = dict[key], let found = recursiveICE(nested) { return found }
            }
            if dict["candidate"] != nil { return recursiveICE([dict]) }
        }
        if let text = value as? String, let data = text.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) { return recursiveICE(decoded) }
        return nil
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCloudError.invalidResponse("Invalid JSON response.")
        }
        return value
    }

    private func string(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static let deviceInfo = """
    {"appInfo":{"env":{"clientAppId":"www.xbox.com","clientAppType":"browser","clientAppVersion":"21.1.98","clientSdkVersion":"8.5.3","httpEnvironment":"prod","sdkInstallId":""}},"dev":{"hw":{"make":"Microsoft","model":"unknown","sdktype":"web"},"os":{"name":"windows","ver":"22631.2715","platform":"desktop"},"displayInfo":{"dimensions":{"widthInPixels":1920,"heightInPixels":1080},"pixelDensity":{"dpiX":2,"dpiY":2}},"browser":{"browserName":"chrome","browserVersion":"119.0"}}}
    """
}

struct XCloudICECandidate: Sendable {
    let candidate: String
    let mLineIndex: Int
    let mid: String
    let usernameFragment: String?
}
