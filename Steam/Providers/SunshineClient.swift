import Foundation
import OSLog
import Security
import UIKit

struct SunshineServerInfo: Equatable, Sendable {
    let statusCode: Int
    let statusMessage: String
    let hostName: String?
    let uniqueId: String?
    let appVersion: String?
    let state: String?
    let currentGame: String?
    let localIp: String?
    let macAddress: String?
    let httpsPort: Int?
    let pairStatus: Int?
    let serverCodecModeSupport: Int?

    nonisolated var isStatusOK: Bool {
        statusCode == 200
    }

    nonisolated var isPaired: Bool {
        pairStatus == 1
    }
}

struct SunshineLaunchResult: Equatable, Sendable {
    let statusCode: Int
    let statusMessage: String
    let sessionUrl: String?
    let riKeyHex: String
    let riKeyId: Int
    let rawFields: [String: String]

    nonisolated var isStatusOK: Bool {
        statusCode == 200
    }
}

enum SunshineClientError: LocalizedError {
    case missingHost
    case invalidURL
    case notPaired
    case missingServerCertificate
    case httpStatus(Int)
    case invalidResponse
    case hostRejected(String)
    case launchRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingHost:
            return "Enter a Sunshine host address first."
        case .invalidURL:
            return "The Sunshine host address is not valid."
        case .notPaired:
            return "Pair Sunshine before loading its games."
        case .missingServerCertificate:
            return "CloudNow is missing Sunshine's paired certificate. Pair Sunshine again."
        case .httpStatus(let status):
            return "Sunshine returned HTTP \(status)."
        case .invalidResponse:
            return "Sunshine responded, but CloudNow could not read the response."
        case .hostRejected(let message):
            return message
        case .launchRejected(let message):
            return message
        }
    }
}

actor SunshineClient {
    // Must match CNMoonlightUniqueID in CNMoonlightPairer.m.
    private static let moonlightUniqueID = "535445414D54564F"
    private let urlSession: URLSession
    private let logger = Logger(subsystem: "CloudNow", category: "Sunshine")

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fetchServerInfo(host: SunshineHost, fastFail: Bool = false) async throws -> SunshineServerInfo {
        guard !host.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SunshineClientError.missingHost
        }
        guard let url = serverInfoURL(host: host) else {
            throw SunshineClientError.invalidURL
        }

        logger.info("Fetching serverinfo host=\(host.name, privacy: .public) endpoint=\(url.absoluteString, privacy: .public)")

        var request = URLRequest(url: url)
        request.timeoutInterval = fastFail ? 5 : 15
        request.setValue("CloudNow tvOS", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            logger.error("serverinfo failed host=\(host.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            logger.error("serverinfo HTTP failure status=\(http.statusCode) host=\(host.name, privacy: .public)")
            throw SunshineClientError.httpStatus(http.statusCode)
        }

        let info = try await MainActor.run {
            try SunshineServerInfoParser.parse(data)
        }
        guard info.isStatusOK else {
            logger.error("serverinfo rejected status=\(info.statusCode) message=\(info.statusMessage, privacy: .public)")
            throw SunshineClientError.hostRejected(info.statusMessage)
        }
        logger.info("serverinfo ok host=\(info.hostName ?? host.name, privacy: .public) state=\(info.state ?? "not reported", privacy: .public) pairStatus=\(info.pairStatus ?? -1) httpsPort=\(info.httpsPort ?? -1)")
        return info
    }

    func fetchAppList(host: SunshineHost) async throws -> [SunshineGame] {
        guard host.isPaired else {
            throw SunshineClientError.notPaired
        }
        guard let serverCertificateDER = host.serverCertificateDER else {
            throw SunshineClientError.missingServerCertificate
        }
        guard let url = appListURL(host: host) else {
            throw SunshineClientError.invalidURL
        }

        logger.info("Fetching applist host=\(host.name, privacy: .public) endpoint=\(url.absoluteString, privacy: .public)")

        let delegate = SunshinePinnedCertificateDelegate(serverCertificateDER: serverCertificateDER)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 15
        request.setValue("CloudNow tvOS", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            logger.error("applist failed host=\(host.name, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            logger.error("applist HTTP failure status=\(http.statusCode) host=\(host.name, privacy: .public)")
            throw SunshineClientError.httpStatus(http.statusCode)
        }

        let games = try await MainActor.run {
            try SunshineAppListParser.parse(data)
        }
        let webApps = await fetchWebApps(host: host, serverCertificateDER: serverCertificateDER)
        let gamesWithWebMetadata = mergeWebApps(webApps, into: games)
        let gamesWithAssets = await gamesWithCachedAssets(gamesWithWebMetadata, host: host, serverCertificateDER: serverCertificateDER)
        logger.info("applist ok host=\(host.name, privacy: .public) count=\(gamesWithAssets.count)")
        return gamesWithAssets
    }

    func launchApp(host: SunshineHost, appId: String, settings: StreamSettings) async throws -> SunshineLaunchResult {
        try await launchOrResumeApp(host: host, appId: appId, settings: settings, verb: "launch")
    }

    func resumeApp(host: SunshineHost, appId: String, settings: StreamSettings) async throws -> SunshineLaunchResult {
        try await launchOrResumeApp(host: host, appId: appId, settings: settings, verb: "resume")
    }

    func cancelRunningApp(host: SunshineHost) async throws {
        guard host.isPaired else {
            throw SunshineClientError.notPaired
        }
        guard let serverCertificateDER = host.serverCertificateDER else {
            throw SunshineClientError.missingServerCertificate
        }
        guard let url = cancelURL(host: host) else {
            throw SunshineClientError.invalidURL
        }

        logger.info("Cancelling Sunshine app host=\(host.name, privacy: .public) endpoint=\(url.absoluteString, privacy: .public)")
        let _ = try await fetchPinnedData(url: url, host: host, serverCertificateDER: serverCertificateDER, timeout: 5)
    }

    private func launchOrResumeApp(host: SunshineHost, appId: String, settings: StreamSettings, verb: String) async throws -> SunshineLaunchResult {
        guard host.isPaired else {
            throw SunshineClientError.notPaired
        }
        guard let serverCertificateDER = host.serverCertificateDER else {
            throw SunshineClientError.missingServerCertificate
        }
        let riKey = randomHex(byteCount: 16)
        let riKeyId = Int.random(in: 0...Int(Int32.max))
        guard let url = launchURL(host: host, verb: verb, appId: appId, settings: settings, riKey: riKey, riKeyId: riKeyId) else {
            throw SunshineClientError.invalidURL
        }

        logger.info("\(verb, privacy: .public) Sunshine app host=\(host.name, privacy: .public) appId=\(appId, privacy: .public) endpoint=\(url.absoluteString, privacy: .public)")

        let delegate = SunshinePinnedCertificateDelegate(serverCertificateDER: serverCertificateDER)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("CloudNow tvOS", forHTTPHeaderField: "User-Agent")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if let urlError = error as? URLError, urlError.code == .timedOut {
                logger.warning("\(verb, privacy: .public) request timed out after host accepted app launch; trying stream with default RTSP port")
                return SunshineLaunchResult(
                    statusCode: 200,
                    statusMessage: "Sunshine launch request timed out after starting the host app. Trying stream connection.",
                    sessionUrl: nil,
                    riKeyHex: riKey,
                    riKeyId: riKeyId,
                    rawFields: ["optimistic": "timeout"]
                )
            }
            logger.error("\(verb, privacy: .public) failed host=\(host.name, privacy: .public) appId=\(appId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            throw error
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            logger.error("\(verb, privacy: .public) HTTP failure status=\(http.statusCode) host=\(host.name, privacy: .public) appId=\(appId, privacy: .public)")
            throw SunshineClientError.httpStatus(http.statusCode)
        }

        let result = try await MainActor.run {
            try SunshineLaunchResultParser.parse(data)
        }
        let resultWithKeys = SunshineLaunchResult(
            statusCode: result.statusCode,
            statusMessage: result.statusMessage,
            sessionUrl: result.sessionUrl,
            riKeyHex: riKey,
            riKeyId: riKeyId,
            rawFields: result.rawFields
        )
        guard result.isStatusOK else {
            logger.error("\(verb, privacy: .public) rejected status=\(result.statusCode) message=\(result.statusMessage, privacy: .public)")
            throw SunshineClientError.launchRejected(result.statusMessage)
        }
        logger.info("\(verb, privacy: .public) ok host=\(host.name, privacy: .public) appId=\(appId, privacy: .public) sessionUrl=\(result.sessionUrl ?? "none", privacy: .public)")
        return resultWithKeys
    }

    private func serverInfoURL(host: SunshineHost) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = host.httpPort
        components.path = "/serverinfo"
        components.queryItems = [
            URLQueryItem(name: "uniqueid", value: Self.moonlightUniqueID)
        ]
        return components.url
    }

    private func appListURL(host: SunshineHost) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = host.httpsPort
        components.path = "/applist"
        components.queryItems = [
            URLQueryItem(name: "uniqueid", value: Self.moonlightUniqueID)
        ]
        return components.url
    }

    private func appAssetURL(host: SunshineHost, appId: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = host.httpsPort
        components.path = "/appasset"
        components.queryItems = [
            URLQueryItem(name: "uniqueid", value: Self.moonlightUniqueID),
            URLQueryItem(name: "appid", value: appId),
            URLQueryItem(name: "AssetType", value: "2"),
            URLQueryItem(name: "AssetIdx", value: "0")
        ]
        return components.url
    }

    private func webAppsURLCandidates(host: SunshineHost) -> [URL] {
        var urls: [URL] = []
        func append(scheme: String, port: Int) {
            var components = URLComponents()
            components.scheme = scheme
            components.host = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
            components.port = port
            components.path = "/api/apps"
            if let url = components.url, !urls.contains(url) {
                urls.append(url)
            }
        }

        append(scheme: "https", port: host.httpsPort)
        append(scheme: "http", port: host.httpPort)
        append(scheme: "https", port: 47990)
        append(scheme: "http", port: 47990)
        return urls
    }

    private func launchURL(
        host: SunshineHost,
        verb: String,
        appId: String,
        settings: StreamSettings,
        riKey: String,
        riKeyId: Int
    ) -> URL? {
        let resolution = settings.resolution.split(separator: "x").compactMap { Int($0) }
        let width = resolution.first ?? 1920
        let height = resolution.dropFirst().first ?? 1080

        var components = URLComponents()
        components.scheme = "https"
        components.host = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = host.httpsPort
        components.path = "/\(verb)"
        components.queryItems = [
            URLQueryItem(name: "uniqueid", value: Self.moonlightUniqueID),
            URLQueryItem(name: "appid", value: appId),
            URLQueryItem(name: "mode", value: "\(width)x\(height)x\(settings.fps)"),
            URLQueryItem(name: "additionalStates", value: "1"),
            URLQueryItem(name: "sops", value: settings.sunshineOptimizeGameSettings ? "1" : "0"),
            URLQueryItem(name: "rikey", value: riKey),
            URLQueryItem(name: "rikeyid", value: "\(riKeyId)"),
            URLQueryItem(name: "localAudioPlayMode", value: "0"),
            // Moonlight surroundAudioInfo: high word is the 7.1 speaker mask
            // (0x063f), low word is the channel count (8).
            URLQueryItem(name: "surroundAudioInfo", value: "104792072"),
            URLQueryItem(name: "remoteControllersBitmap", value: "1"),
            URLQueryItem(name: "gcmap", value: "1"),
            URLQueryItem(name: "gcpersist", value: "1")
        ]
        appendLaunchQueryParameters(to: &components)
        return components.url
    }

    private func cancelURL(host: SunshineHost) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host.address.trimmingCharacters(in: .whitespacesAndNewlines)
        components.port = host.httpsPort
        components.path = "/cancel"
        components.queryItems = [
            URLQueryItem(name: "uniqueid", value: Self.moonlightUniqueID)
        ]
        return components.url
    }

    private func appendLaunchQueryParameters(to components: inout URLComponents) {
        let query = CNMoonlightStreamBridge.launchQueryParameters()
            .trimmingCharacters(in: CharacterSet(charactersIn: "&?"))
        guard !query.isEmpty else { return }

        let extraItems = query
            .split(separator: "&")
            .compactMap { pair -> URLQueryItem? in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let name = parts.first, !name.isEmpty else { return nil }
                return URLQueryItem(name: name, value: parts.count > 1 ? parts[1] : nil)
            }
        components.queryItems = (components.queryItems ?? []) + extraItems
    }

    private func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        if status != errSecSuccess {
            bytes = (0..<byteCount).map { _ in UInt8.random(in: 0...255) }
        }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    private func gamesWithCachedAssets(
        _ games: [SunshineGame],
        host: SunshineHost,
        serverCertificateDER: Data
    ) async -> [SunshineGame] {
        var enriched: [SunshineGame] = []
        for game in games {
            let assetUrl = await cachedAssetURL(for: game, host: host, serverCertificateDER: serverCertificateDER)
            enriched.append(
                SunshineGame(
                    appId: game.appId,
                    title: game.title,
                    boxArtUrl: assetUrl?.absoluteString ?? game.boxArtUrl,
                    heroBannerUrl: game.heroBannerUrl,
                    launchCommand: game.launchCommand,
                    workingDirectory: game.workingDirectory,
                    imagePath: game.imagePath,
                    uniqueIdentifier: game.uniqueIdentifier,
                    rawFields: game.rawFields
                )
            )
        }
        return enriched
    }

    private func fetchWebApps(host: SunshineHost, serverCertificateDER: Data) async -> [SunshineWebApp] {
        for url in webAppsURLCandidates(host: host) {
            do {
                let data: Data
                if url.scheme == "https" {
                    data = try await fetchPinnedData(
                        url: url,
                        host: host,
                        serverCertificateDER: serverCertificateDER,
                        timeout: 5,
                        headers: webAPIHeaders(for: host)
                    )
                } else {
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 5
                    request.setValue("CloudNow tvOS", forHTTPHeaderField: "User-Agent")
                    for (field, value) in webAPIHeaders(for: host) {
                        request.setValue(value, forHTTPHeaderField: field)
                    }
                    let (body, response) = try await urlSession.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        continue
                    }
                    data = body
                }
                let apps = try SunshineWebAppsParser.parse(data)
                logger.info("web apps ok endpoint=\(url.absoluteString, privacy: .public) count=\(apps.count)")
                return apps
            } catch {
                logger.info("web apps unavailable endpoint=\(url.absoluteString, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return []
    }

    private func webAPIHeaders(for host: SunshineHost) -> [String: String] {
        let username = host.webUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !host.webPassword.isEmpty else { return [:] }
        let credential = "\(username):\(host.webPassword)"
        guard let data = credential.data(using: .utf8) else { return [:] }
        return ["Authorization": "Basic \(data.base64EncodedString())"]
    }

    private func mergeWebApps(_ webApps: [SunshineWebApp], into games: [SunshineGame]) -> [SunshineGame] {
        guard !webApps.isEmpty else { return games }
        let webAppsByName = Dictionary(grouping: webApps, by: { normalizedAppMatchKey($0.name) })
        return games.map { game in
            let nameMatches = webAppsByName[normalizedAppMatchKey(game.title)] ?? []
            let commandMatches = nameMatches.filter { webApp in
                guard let gameCommand = game.launchCommand, let webCommand = webApp.command else { return false }
                return gameCommand == webCommand
            }
            guard let webApp = commandMatches.first ?? nameMatches.first else { return game }
            var rawFields = game.rawFields
            for (key, value) in webApp.fields where rawFields[key] == nil {
                rawFields[key] = value
            }
            return SunshineGame(
                appId: game.appId,
                title: game.title,
                boxArtUrl: game.boxArtUrl,
                heroBannerUrl: game.heroBannerUrl,
                launchCommand: game.launchCommand ?? webApp.command,
                workingDirectory: game.workingDirectory ?? webApp.workingDirectory,
                imagePath: game.imagePath ?? webApp.imagePath,
                uniqueIdentifier: game.uniqueIdentifier,
                rawFields: rawFields
            )
        }
    }

    private func normalizedAppMatchKey(_ value: String?) -> String {
        (value ?? "")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cachedAssetURL(
        for game: SunshineGame,
        host: SunshineHost,
        serverCertificateDER: Data
    ) async -> URL? {
        let fileUrl = assetCacheURL(host: host, appId: game.appId)
        if FileManager.default.fileExists(atPath: fileUrl.path) {
            logger.info("using saved app artwork host=\(host.name, privacy: .public) appId=\(game.appId, privacy: .public) path=\(fileUrl.path, privacy: .public)")
            return fileUrl
        }
        let legacyUrl = legacyAssetCacheURL(host: host, appId: game.appId)
        if FileManager.default.fileExists(atPath: legacyUrl.path) {
            do {
                try ensureDirectory(fileUrl.deletingLastPathComponent())
                try FileManager.default.copyItem(at: legacyUrl, to: fileUrl)
                logger.info("migrated app artwork host=\(host.name, privacy: .public) appId=\(game.appId, privacy: .public) path=\(fileUrl.path, privacy: .public)")
                return fileUrl
            } catch {
                logger.info("app artwork migration failed host=\(host.name, privacy: .public) appId=\(game.appId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            }
        }
        guard let remoteUrl = appAssetURL(host: host, appId: game.appId) else {
            return nil
        }

        do {
            let data = try await fetchPinnedData(url: remoteUrl, host: host, serverCertificateDER: serverCertificateDER, timeout: 15)
            guard !data.isEmpty else {
                logger.info("app asset empty host=\(host.name, privacy: .public) appId=\(game.appId, privacy: .public)")
                return nil
            }
            guard let image = UIImage(data: data), let png = image.pngData() else {
                let preview = String(data: data.prefix(80), encoding: .utf8) ?? "non-text response"
                logger.info("app asset was not an image host=\(host.name, privacy: .public) appId=\(game.appId, privacy: .public) bytes=\(data.count) preview=\(preview, privacy: .public)")
                return nil
            }
            try ensureDirectory(fileUrl.deletingLastPathComponent())
            try png.write(to: fileUrl, options: [.atomic])
            logger.info("saved app artwork host=\(host.name, privacy: .public) appId=\(game.appId, privacy: .public) bytes=\(png.count) path=\(fileUrl.path, privacy: .public)")
            return fileUrl
        } catch {
            logger.info("app asset unavailable host=\(host.name, privacy: .public) appId=\(game.appId, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func fetchPinnedData(
        url: URL,
        host: SunshineHost,
        serverCertificateDER: Data,
        timeout: TimeInterval,
        headers: [String: String] = [:]
    ) async throws -> Data {
        let delegate = SunshinePinnedCertificateDelegate(serverCertificateDER: serverCertificateDER)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("CloudNow tvOS", forHTTPHeaderField: "User-Agent")
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SunshineClientError.httpStatus(http.statusCode)
        }
        return data
    }

    private func ensureDirectory(_ directory: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func assetCacheURL(host: SunshineHost, appId: String) -> URL {
        let safeHost = safeFilename("\(host.address)-\(host.httpsPort)")
        let safeAppId = safeFilename(appId)
        return Self.cloudNowArtworkDirectory
            .appendingPathComponent("SunshineAssets", isDirectory: true)
            .appendingPathComponent(safeHost, isDirectory: true)
            .appendingPathComponent("\(safeAppId).png", isDirectory: false)
    }

    private func legacyAssetCacheURL(host: SunshineHost, appId: String) -> URL {
        let safeHost = safeFilename("\(host.address)-\(host.httpsPort)")
        let safeAppId = safeFilename(appId)
        return Self.legacyCloudNowCacheDirectory
            .appendingPathComponent("SunshineAssets", isDirectory: true)
            .appendingPathComponent(safeHost, isDirectory: true)
            .appendingPathComponent("\(safeAppId).png", isDirectory: false)
    }

    private static var cloudNowArtworkDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CloudNow", isDirectory: true)
    }

    private static var legacyCloudNowCacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CloudNow", isDirectory: true)
    }

    private func safeFilename(_ value: String) -> String {
        value.map { character in
            character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
        }
        .reduce(into: "") { $0.append($1) }
    }
}

private final class SunshinePinnedCertificateDelegate: NSObject, URLSessionDelegate {
    private let serverCertificateDER: Data

    init(serverCertificateDER: Data) {
        self.serverCertificateDER = serverCertificateDER
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate,
           let credential = clientCertificateCredential() {
            return (.useCredential, credential)
        }

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              SecTrustGetCertificateCount(trust) == 1,
              let certificate = SecTrustGetCertificateAtIndex(trust, 0) else {
            return (.performDefaultHandling, nil)
        }

        let actual = SecCertificateCopyData(certificate) as Data
        guard actual == serverCertificateDER else {
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.useCredential, URLCredential(trust: trust))
    }

    private func clientCertificateCredential() -> URLCredential? {
        guard let p12 = UserDefaults.standard.data(forKey: "client.p12") else {
            return nil
        }

        let options = [kSecImportExportPassphrase as String: "limelight"]
        var rawItems: CFArray?
        let status = SecPKCS12Import(p12 as CFData, options as CFDictionary, &rawItems)
        guard status == errSecSuccess,
              let items = rawItems as? [[String: Any]],
              let identity = items.first?[kSecImportItemIdentity as String] else {
            return nil
        }

        let secIdentity = identity as! SecIdentity
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(secIdentity, &certificate)
        let certificates = certificate.map { [$0] }
        return URLCredential(
            identity: secIdentity,
            certificates: certificates,
            persistence: .forSession
        )
    }
}

private struct SunshineWebApp: Sendable {
    let fields: [String: String]

    nonisolated var name: String? {
        fields["name"] ?? fields["Name"] ?? fields["AppTitle"] ?? fields["Title"]
    }

    nonisolated var command: String? {
        fields["cmd"] ?? fields["Command"] ?? fields["LaunchCommand"] ?? fields["AppCmd"]
    }

    nonisolated var workingDirectory: String? {
        fields["working-dir"] ?? fields["workingDirectory"] ?? fields["workingdir"] ?? fields["WorkingDir"]
    }

    nonisolated var imagePath: String? {
        fields["image-path"] ?? fields["ImagePath"] ?? fields["CoverPath"] ?? fields["BoxArtPath"] ?? fields["ArtworkPath"]
    }
}

private enum SunshineWebAppsParser {
    nonisolated static func parse(_ data: Data) throws -> [SunshineWebApp] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let apps = root["apps"] as? [[String: Any]] else {
            throw SunshineClientError.invalidResponse
        }
        return apps.map { app in
            SunshineWebApp(fields: app.compactMapValues(stringValue))
        }
    }

    nonisolated private static func stringValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let bool as Bool:
            return bool ? "true" : "false"
        case let array as [Any]:
            guard JSONSerialization.isValidJSONObject(array),
                  let data = try? JSONSerialization.data(withJSONObject: array),
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case let object as [String: Any]:
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        default:
            return nil
        }
    }
}

private final class SunshineServerInfoParser: NSObject, XMLParserDelegate {
    private var values: [String: String] = [:]
    private var currentElement: String?
    private var currentValue = ""
    private var rootStatusCode: Int?
    private var rootStatusMessage: String?

    static func parse(_ data: Data) throws -> SunshineServerInfo {
        let parserDelegate = SunshineServerInfoParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw SunshineClientError.invalidResponse
        }
        return parserDelegate.result()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if rootStatusCode == nil, let status = attributeDict["status_code"] {
            rootStatusCode = Int(status)
            rootStatusMessage = attributeDict["status_message"]
        }
        currentElement = elementName
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            values[elementName.lowercased()] = value
        }
        currentElement = nil
        currentValue = ""
    }

    private func result() -> SunshineServerInfo {
        SunshineServerInfo(
            statusCode: rootStatusCode ?? -1,
            statusMessage: rootStatusMessage ?? (rootStatusCode == 200 ? "OK" : "Sunshine did not return a status."),
            hostName: value("hostname"),
            uniqueId: value("uniqueid"),
            appVersion: value("appversion"),
            state: value("state"),
            currentGame: value("currentgame"),
            localIp: value("localip"),
            macAddress: value("mac"),
            httpsPort: intValue("httpsport"),
            pairStatus: intValue("pairstatus"),
            serverCodecModeSupport: intValue("servercodecmodesupport")
        )
    }

    private func value(_ key: String) -> String? {
        values[key]
    }

    private func intValue(_ key: String) -> Int? {
        values[key].flatMap(Int.init)
    }
}

private final class SunshineAppListParser: NSObject, XMLParserDelegate {
    private var rootStatusCode: Int?
    private var rootStatusMessage: String?
    private var currentElement: String?
    private var currentValue = ""
    private var inApp = false
    private var currentAppValues: [String: String] = [:]
    private var apps: [SunshineGame] = []

    static func parse(_ data: Data) throws -> [SunshineGame] {
        let parserDelegate = SunshineAppListParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw SunshineClientError.invalidResponse
        }
        return try parserDelegate.result()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if rootStatusCode == nil, let status = attributeDict["status_code"] {
            rootStatusCode = Int(status)
            rootStatusMessage = attributeDict["status_message"]
        }

        if elementName == "App" {
            inApp = true
            currentAppValues = [:]
        }
        currentElement = elementName
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if inApp, elementName != "App", !value.isEmpty {
            currentAppValues[elementName] = value
        }

        if elementName == "App" {
            if let appId = firstValue(["ID", "AppID", "AppId", "id", "appid"]), !appId.isEmpty {
                let title = firstValue(["AppTitle", "Name", "Title", "name", "title"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                apps.append(
                    SunshineGame(
                        appId: appId,
                        title: title?.isEmpty == false ? title! : appId,
                        boxArtUrl: nil,
                        heroBannerUrl: nil,
                        launchCommand: firstValue([
                            "LaunchCommand",
                            "Command",
                            "Cmd",
                            "AppCmd",
                            "Detached",
                            "launch-command",
                            "command",
                            "cmd",
                            "detached"
                        ]),
                        workingDirectory: firstValue([
                            "WorkingDir",
                            "WorkingDirectory",
                            "StartDir",
                            "working-dir",
                            "workingDirectory",
                            "workingdir"
                        ]),
                        imagePath: firstValue([
                            "ImagePath",
                            "CoverPath",
                            "BoxArtPath",
                            "PosterPath",
                            "AssetPath",
                            "image-path",
                            "cover",
                            "boxart",
                            "boxArt"
                        ]),
                        uniqueIdentifier: firstValue([
                            "UUID",
                            "Uuid",
                            "GUID",
                            "Guid",
                            "UniqueID",
                            "UniqueId",
                            "uniqueid"
                        ]) ?? appId,
                        rawFields: currentAppValues
                    )
                )
            }
            inApp = false
            currentAppValues = [:]
        }
        currentElement = nil
        currentValue = ""
    }

    private func result() throws -> [SunshineGame] {
        let statusCode = rootStatusCode ?? -1
        guard statusCode == 200 else {
            throw SunshineClientError.hostRejected(rootStatusMessage ?? "Sunshine did not return an app list.")
        }
        return apps.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func firstValue(_ keys: [String]) -> String? {
        for key in keys {
            if let value = currentAppValues[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        let lowered = Dictionary(uniqueKeysWithValues: currentAppValues.map { ($0.key.lowercased(), $0.value) })
        for key in keys {
            if let value = lowered[key.lowercased()]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

private final class SunshineLaunchResultParser: NSObject, XMLParserDelegate {
    private var values: [String: String] = [:]
    private var currentElement: String?
    private var currentValue = ""
    private var rootStatusCode: Int?
    private var rootStatusMessage: String?

    static func parse(_ data: Data) throws -> SunshineLaunchResult {
        let parserDelegate = SunshineLaunchResultParser()
        let parser = XMLParser(data: data)
        parser.delegate = parserDelegate
        guard parser.parse() else {
            throw SunshineClientError.invalidResponse
        }
        return parserDelegate.result()
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if rootStatusCode == nil, let status = attributeDict["status_code"] {
            rootStatusCode = Int(status)
            rootStatusMessage = attributeDict["status_message"]
        }
        currentElement = elementName
        currentValue = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
            values[elementName.lowercased()] = value
        }
        currentElement = nil
        currentValue = ""
    }

    private func result() -> SunshineLaunchResult {
        let statusCode = rootStatusCode
            ?? Int(values["status_code"] ?? "")
            ?? Int(values["statuscode"] ?? "")
            ?? 200
        let message = rootStatusMessage
            ?? values["status_message"]
            ?? values["statusmessage"]
            ?? (statusCode == 200 ? "Sunshine accepted the launch." : "Sunshine rejected the launch.")
        return SunshineLaunchResult(
            statusCode: statusCode,
            statusMessage: message,
            sessionUrl: values["sessionurl0"] ?? values["sessionurl"] ?? values["rtspurl"] ?? values["url"],
            riKeyHex: "",
            riKeyId: 0,
            rawFields: values
        )
    }
}
