import Foundation
import Observation

enum GameProviderID: String, Codable, CaseIterable, Hashable, Sendable {
    case geforceNow = "geforce-now"
    case sunshine = "sunshine"
    case xcloud = "xcloud"

    var displayName: String {
        switch self {
        case .geforceNow:
            return "GeForce NOW"
        case .sunshine:
            return "Sunshine"
        case .xcloud:
            return "Xbox Cloud Gaming"
        }
    }

    var shortName: String {
        switch self {
        case .geforceNow:
            return "GFN"
        case .sunshine:
            return "Sunshine"
        case .xcloud:
            return "Xbox"
        }
    }
}

enum GameLaunchAvailability: String, Codable, Equatable, Sendable {
    case ready
    case available
    case active
    case unavailable

    var label: String {
        switch self {
        case .ready:
            return "Ready"
        case .available:
            return "Available"
        case .active:
            return "Active"
        case .unavailable:
            return "Unavailable"
        }
    }
}

struct UnifiedGame: Identifiable, Equatable, Codable, Sendable {
    let providerID: GameProviderID
    let providerGameID: String
    let title: String
    let boxArtUrl: String?
    let heroBannerUrl: String?
    var availability: GameLaunchAvailability
    var sourceDetail: String?

    var id: String {
        "\(providerID.rawValue):\(providerGameID)"
    }
}

enum ArtworkRole: String, Codable, Equatable, Sendable {
    case tileCover
    case heroBackground
    case screenshot
    case fallbackBlurredCover
}

enum ArtworkSource: String, Codable, Equatable, Sendable {
    case sunshineSelectedCover
    case geforceNow
    case igdb
    case gameDB
    case steamGridDB
    case providerMetadata
    case fallback
}

struct ArtworkAsset: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var role: ArtworkRole
    var source: ArtworkSource
    var url: String
    var isUserSelected: Bool
    var isPreferred: Bool
}

struct ExternalGameIds: Equatable, Codable, Sendable {
    var igdbId: String?
    var gameDBId: String?
    var steamAppId: String?
    var xboxId: String?
    var epicId: String?

    var hasProviderIdentity: Bool {
        igdbId != nil || gameDBId != nil || steamAppId != nil || xboxId != nil || epicId != nil
    }

    mutating func mergeMissing(from other: ExternalGameIds) {
        igdbId = igdbId ?? other.igdbId
        gameDBId = gameDBId ?? other.gameDBId
        steamAppId = steamAppId ?? other.steamAppId
        xboxId = xboxId ?? other.xboxId
        epicId = epicId ?? other.epicId
    }
}

enum MatchSource: String, Codable, Equatable, Hashable, Sendable {
    case sunshineSelectedCover
    case sunshineCoverFilename
    case igdbId
    case gameDBId
    case exactTitle
    case fuzzyTitle
    case commandPath
    case userConfirmed
    case standaloneSunshine
    case needsReview
}

struct LaunchOption: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var providerID: GameProviderID
    var providerGameID: String
    var title: String
    var launchCommand: String?
    var workingDirectory: String?
    var hostUniqueId: String?
    var isPreferred: Bool
}

struct ProviderGameEntry: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var providerID: GameProviderID
    var providerGameID: String
    var title: String
    var launchCommand: String?
    var workingDirectory: String?
    var imagePath: String?
    var coverUrl: String?
    var uniqueProviderIdentifier: String?
    var rawFields: [String: String]
}

struct CanonicalGame: Identifiable, Equatable, Codable, Sendable {
    var id: String
    var title: String
    var platform: String?
    var releaseDate: String?
    var releaseYear: Int?
    var developer: String?
    var publisher: String?
    var genres: [String]
    var summary: String?
    var externalIds: ExternalGameIds
    var providerEntries: [ProviderGameEntry]
    var launchOptions: [LaunchOption]
    var artwork: [ArtworkAsset]
    var matchConfidence: Double
    var matchSources: [MatchSource]
    var needsReview: Bool
}

protocol GameCatalogProvider: Sendable {
    var id: GameProviderID { get }
    var displayName: String { get }

    func loadCatalog() async throws -> [UnifiedGame]
}

extension GameCatalogProvider {
    var displayName: String { id.displayName }
}

struct SunshineHost: Codable, Equatable, Sendable {
    var name: String
    var address: String
    var httpPort: Int
    var httpsPort: Int
    var macAddress: String
    var webUsername: String
    var webPassword: String
    var uniqueId: String?
    var serverCertificateDER: Data?
    var isPaired: Bool

    static let defaultHTTPPort = 47989
    static let defaultHTTPSPort = 47984
}

extension SunshineHost {
    enum CodingKeys: String, CodingKey {
        case name, address, httpPort, httpsPort, macAddress, webUsername, webPassword, uniqueId, serverCertificateDER, isPaired
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        address = try container.decode(String.self, forKey: .address)
        httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? Self.defaultHTTPPort
        httpsPort = try container.decodeIfPresent(Int.self, forKey: .httpsPort) ?? Self.defaultHTTPSPort
        macAddress = try container.decodeIfPresent(String.self, forKey: .macAddress) ?? ""
        webUsername = try container.decodeIfPresent(String.self, forKey: .webUsername) ?? "sunshine"
        webPassword = try container.decodeIfPresent(String.self, forKey: .webPassword) ?? ""
        uniqueId = try container.decodeIfPresent(String.self, forKey: .uniqueId)
        serverCertificateDER = try container.decodeIfPresent(Data.self, forKey: .serverCertificateDER)
        isPaired = try container.decodeIfPresent(Bool.self, forKey: .isPaired) ?? false
    }
}

@MainActor
@Observable
final class SunshineHostStore {
    var name: String
    var address: String
    var httpPort: Int
    var httpsPort: Int
    var macAddress: String
    var webUsername: String
    var webPassword: String
    var uniqueId: String?
    var serverCertificateDER: Data?
    var isPaired: Bool

    private static let storageKey = "sunshine.singleHost"
    private static let verifiedWakeMACByHost = [
        "192.168.0.125": "a8:a1:59:b5:e9:6d"
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let host = try? JSONDecoder().decode(SunshineHost.self, from: data) {
            let repairedMAC = Self.normalizedUsableMACAddress(host.macAddress)
                ?? Self.verifiedWakeMACByHost[host.address.trimmingCharacters(in: .whitespacesAndNewlines)]
                ?? ""
            name = host.name
            address = host.address
            httpPort = host.httpPort
            httpsPort = host.httpsPort
            macAddress = repairedMAC
            webUsername = host.webUsername
            webPassword = host.webPassword
            uniqueId = host.uniqueId
            serverCertificateDER = host.serverCertificateDER
            isPaired = host.isPaired
            if repairedMAC != host.macAddress {
                save()
            }
        } else {
            name = "Gaming PC"
            address = ""
            httpPort = SunshineHost.defaultHTTPPort
            httpsPort = SunshineHost.defaultHTTPSPort
            macAddress = ""
            webUsername = "sunshine"
            webPassword = ""
            uniqueId = nil
            serverCertificateDER = nil
            isPaired = false
        }
    }

    var isConfigured: Bool {
        !normalizedAddress.isEmpty
    }

    var host: SunshineHost? {
        guard isConfigured else { return nil }
        return SunshineHost(
            name: normalizedName,
            address: normalizedAddress,
            httpPort: httpPort,
            httpsPort: httpsPort,
            macAddress: normalizedMACAddress,
            webUsername: webUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            webPassword: webPassword,
            uniqueId: uniqueId,
            serverCertificateDER: serverCertificateDER,
            isPaired: isPaired
        )
    }

    var statusText: String {
        guard let host else { return "Not paired" }
        return isPaired ? "Paired · \(host.address):\(host.httpsPort)" : "Saved · pairing needed"
    }

    var portText: String {
        String(httpsPort)
    }

    func save() {
        name = normalizedName
        address = normalizedAddress
        macAddress = normalizedMACAddress
        webUsername = webUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        httpPort = min(max(httpPort, 1), 65_535)
        httpsPort = min(max(httpsPort, 1), 65_535)
        if normalizedAddress.isEmpty {
            isPaired = false
            uniqueId = nil
            serverCertificateDER = nil
        }

        guard let host else {
            UserDefaults.standard.removeObject(forKey: Self.storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(host) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    func clear() {
        name = "Gaming PC"
        address = ""
        httpPort = SunshineHost.defaultHTTPPort
        httpsPort = SunshineHost.defaultHTTPSPort
        macAddress = ""
        webUsername = "sunshine"
        webPassword = ""
        uniqueId = nil
        serverCertificateDER = nil
        isPaired = false
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    func markPairingNeeded() {
        isPaired = false
        save()
    }

    func completePairing() {
        isPaired = true
        save()
    }

    func completePairing(uniqueId: String?, serverCertificateDER: Data?, httpsPort: Int?, hostName: String?, macAddress: String? = nil) {
        if let hostName, !hostName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            name = hostName
        }
        self.uniqueId = uniqueId ?? self.uniqueId
        self.serverCertificateDER = serverCertificateDER ?? self.serverCertificateDER
        if let httpsPort, httpsPort > 0 {
            self.httpsPort = httpsPort
        }
        if let macAddress = macAddress.flatMap(Self.normalizedUsableMACAddress) {
            self.macAddress = macAddress
        }
        isPaired = true
        save()
    }

    func updateWakeMACAddress(_ value: String?) {
        guard let normalized = value.flatMap(Self.normalizedUsableMACAddress) else { return }
        guard macAddress != normalized else { return }
        macAddress = normalized
        save()
    }

    func newPairingPIN() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    private var normalizedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Gaming PC" : trimmed
    }

    private var normalizedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedMACAddress: String {
        Self.normalizedUsableMACAddress(macAddress)
            ?? Self.verifiedWakeMACByHost[normalizedAddress]
            ?? ""
    }

    private static func normalizedUsableMACAddress(_ value: String) -> String? {
        let compact = value.filter { $0.isHexDigit }
        guard compact.count == 12 else { return nil }
        let lowercased = compact.lowercased()
        guard lowercased != String(repeating: "0", count: 12),
              lowercased != String(repeating: "f", count: 12),
              let firstOctet = UInt8(lowercased.prefix(2), radix: 16),
              firstOctet & 1 == 0 else {
            return nil
        }
        return stride(from: 0, to: 12, by: 2)
            .map { index in
                let start = lowercased.index(lowercased.startIndex, offsetBy: index)
                let end = lowercased.index(start, offsetBy: 2)
                return String(lowercased[start..<end])
            }
            .joined(separator: ":")
    }
}

enum SunshinePowerAction: String, CaseIterable, Identifiable, Sendable {
    case wake
    case sleep
    case shutdown

    var id: Self { self }
}

struct SunshineGame: Identifiable, Equatable, Codable, Sendable {
    let appId: String
    let title: String
    let boxArtUrl: String?
    let heroBannerUrl: String?
    let launchCommand: String?
    let workingDirectory: String?
    let imagePath: String?
    let uniqueIdentifier: String?
    let rawFields: [String: String]

    var id: String { appId }

    var reservedPowerAction: SunshinePowerAction? {
        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sleep": return .sleep
        case "shutdown bc-250": return .shutdown
        default: return nil
        }
    }

    func unifiedGame() -> UnifiedGame {
        UnifiedGame(
            providerID: .sunshine,
            providerGameID: appId,
            title: title,
            boxArtUrl: boxArtUrl,
            heroBannerUrl: heroBannerUrl,
            availability: .ready,
            sourceDetail: "Sunshine"
        )
    }

    func gameInfo() -> GameInfo {
        GameInfo(
            id: "sunshine:\(appId)",
            title: title,
            boxArtUrl: boxArtUrl,
            heroBannerUrl: heroBannerUrl,
            isInLibrary: true,
            variants: [
                GameVariant(
                    id: "sunshine:\(appId)",
                    appStore: GameProviderID.sunshine.shortName.uppercased(),
                    appId: appId,
                    isOwned: true
                )
            ]
        )
    }
}

struct SunshineImportResult: Equatable, Sendable {
    let canonicalGame: CanonicalGame
    let gameInfo: GameInfo
}

struct SunshineGameEnricher: Sendable {
    private let reviewThreshold = 0.82

    func importGames(_ games: [SunshineGame], canonicalDatabase: [GameInfo]) -> [SunshineImportResult] {
        let candidates = deduped(canonicalDatabase)
        return games.map { importGame($0, canonicalDatabase: candidates) }
    }

    private func importGame(_ sunshine: SunshineGame, canonicalDatabase: [GameInfo]) -> SunshineImportResult {
        let selectedCoverIds = externalIdsFromSelectedCover(sunshine)
        let titleMatch = bestTitleMatch(for: sunshine, in: canonicalDatabase)
        let hasCoverIdentity = selectedCoverIds.igdbId != nil || selectedCoverIds.gameDBId != nil
        let matchedGame = shouldAttachToCandidate(titleMatch, hasCoverIdentity: hasCoverIdentity) ? titleMatch?.game : nil
        let confidence = matchConfidence(
            selectedCoverIds: selectedCoverIds,
            titleMatch: titleMatch,
            matchedGame: matchedGame
        )
        var sources = matchSources(
            selectedCoverIds: selectedCoverIds,
            titleMatch: titleMatch,
            matchedGame: matchedGame,
            sunshine: sunshine
        )
        let needsReview = !hasCoverIdentity && confidence < reviewThreshold
        if needsReview {
            sources.append(.needsReview)
        }

        let canonicalId = canonicalID(
            sunshine: sunshine,
            selectedCoverIds: selectedCoverIds,
            matchedGame: matchedGame
        )
        let canonicalTitle = matchedGame?.title ?? sunshine.title
        let platform = platformHint(from: sunshine)
        let providerEntry = ProviderGameEntry(
            id: "sunshine:\(sunshine.appId)",
            providerID: .sunshine,
            providerGameID: sunshine.appId,
            title: sunshine.title,
            launchCommand: sunshine.launchCommand,
            workingDirectory: sunshine.workingDirectory,
            imagePath: sunshine.imagePath,
            coverUrl: sunshine.boxArtUrl,
            uniqueProviderIdentifier: sunshine.uniqueIdentifier,
            rawFields: sunshine.rawFields
        )
        let sunshineLaunch = LaunchOption(
            id: "sunshine:\(sunshine.appId)",
            providerID: .sunshine,
            providerGameID: sunshine.appId,
            title: sunshine.title,
            launchCommand: sunshine.launchCommand,
            workingDirectory: sunshine.workingDirectory,
            hostUniqueId: sunshine.uniqueIdentifier,
            isPreferred: true
        )

        var externalIds = selectedCoverIds
        if let matchedGame {
            externalIds.mergeMissing(from: externalIdsFromVariants(matchedGame.variants))
        }

        let gameInfo = makeGameInfo(
            sunshine: sunshine,
            matchedGame: needsReview ? nil : matchedGame,
            canonicalId: canonicalId,
            confidence: confidence,
            sources: sources
        )
        let canonical = CanonicalGame(
            id: canonicalId,
            title: canonicalTitle,
            platform: platform,
            releaseDate: nil,
            releaseYear: nil,
            developer: nil,
            publisher: nil,
            genres: [],
            summary: nil,
            externalIds: externalIds,
            providerEntries: [providerEntry],
            launchOptions: [sunshineLaunch] + launchOptions(from: matchedGame),
            artwork: artworkAssets(sunshine: sunshine, matchedGame: matchedGame),
            matchConfidence: confidence,
            matchSources: sources,
            needsReview: needsReview
        )
        return SunshineImportResult(canonicalGame: canonical, gameInfo: gameInfo)
    }

    private func shouldAttachToCandidate(
        _ titleMatch: (game: GameInfo, score: Double, source: MatchSource)?,
        hasCoverIdentity: Bool
    ) -> Bool {
        guard let titleMatch else { return false }
        if hasCoverIdentity {
            return titleMatch.score >= 0.70
        }
        return titleMatch.score >= reviewThreshold
    }

    private func makeGameInfo(
        sunshine: SunshineGame,
        matchedGame: GameInfo?,
        canonicalId: String,
        confidence: Double,
        sources: [MatchSource]
    ) -> GameInfo {
        let sunshineVariant = GameVariant(
            id: "sunshine:\(sunshine.appId)",
            appStore: GameProviderID.sunshine.shortName.uppercased(),
            appId: sunshine.appId,
            isOwned: true
        )
        let matchedVariants = matchedGame?.variants.filter { $0.appStore != "SUNSHINE" } ?? []
        let sourceDetail = sources.map(\.rawValue).joined(separator: ",")
        return GameInfo(
            id: matchedGame?.id ?? "sunshine:\(sunshine.appId)",
            title: matchedGame?.title ?? sunshine.title,
            boxArtUrl: sunshine.boxArtUrl ?? matchedGame?.boxArtUrl,
            heroBannerUrl: matchedGame?.heroBannerUrl ?? sunshine.heroBannerUrl,
            isInLibrary: true,
            variants: [sunshineVariant] + matchedVariants,
            canonicalId: canonicalId,
            matchConfidence: confidence,
            matchSource: sourceDetail.isEmpty ? nil : sourceDetail,
            needsReview: sources.contains(.needsReview),
            providerMetadata: matchedGame?.providerMetadata
        )
    }

    private func artworkAssets(sunshine: SunshineGame, matchedGame: GameInfo?) -> [ArtworkAsset] {
        var assets: [ArtworkAsset] = []
        if let cover = sunshine.boxArtUrl ?? sunshine.imagePath {
            assets.append(
                ArtworkAsset(
                    id: "sunshine:\(sunshine.appId):cover",
                    role: .tileCover,
                    source: .sunshineSelectedCover,
                    url: cover,
                    isUserSelected: true,
                    isPreferred: true
                )
            )
        }
        if let hero = matchedGame?.heroBannerUrl {
            assets.append(
                ArtworkAsset(
                    id: "sunshine:\(sunshine.appId):hero",
                    role: .heroBackground,
                    source: .providerMetadata,
                    url: hero,
                    isUserSelected: false,
                    isPreferred: true
                )
            )
        } else if let cover = sunshine.boxArtUrl ?? sunshine.imagePath {
            assets.append(
                ArtworkAsset(
                    id: "sunshine:\(sunshine.appId):hero-fallback",
                    role: .fallbackBlurredCover,
                    source: .fallback,
                    url: cover,
                    isUserSelected: true,
                    isPreferred: false
                )
            )
        }
        return assets
    }

    private func canonicalID(
        sunshine: SunshineGame,
        selectedCoverIds: ExternalGameIds,
        matchedGame: GameInfo?
    ) -> String {
        if let igdbId = selectedCoverIds.igdbId {
            return "igdb:\(igdbId)"
        }
        if let gameDBId = selectedCoverIds.gameDBId {
            return "gamedb:\(gameDBId)"
        }
        if let matchedGame {
            return matchedGame.id
        }
        return "sunshine:\(sunshine.appId)"
    }

    private func matchConfidence(
        selectedCoverIds: ExternalGameIds,
        titleMatch: (game: GameInfo, score: Double, source: MatchSource)?,
        matchedGame: GameInfo?
    ) -> Double {
        if selectedCoverIds.igdbId != nil || selectedCoverIds.gameDBId != nil {
            return max(0.96, titleMatch?.score ?? 0)
        }
        guard matchedGame != nil else {
            return titleMatch?.score ?? 0.40
        }
        return titleMatch?.score ?? 0.40
    }

    private func matchSources(
        selectedCoverIds: ExternalGameIds,
        titleMatch: (game: GameInfo, score: Double, source: MatchSource)?,
        matchedGame: GameInfo?,
        sunshine: SunshineGame
    ) -> [MatchSource] {
        var sources: [MatchSource] = []
        let filenameDerived = selectedCoverHasNumericFilenameIdentity(sunshine)
        if selectedCoverIds.igdbId != nil {
            sources.append(contentsOf: [.sunshineSelectedCover, .igdbId])
            if filenameDerived {
                sources.append(.sunshineCoverFilename)
            }
        }
        if selectedCoverIds.gameDBId != nil {
            sources.append(contentsOf: [.sunshineSelectedCover, .gameDBId])
            if filenameDerived {
                sources.append(.sunshineCoverFilename)
            }
        }
        if matchedGame != nil, let titleMatch {
            sources.append(titleMatch.source)
            if titleMatch.score > 0.88 {
                sources.append(.commandPath)
            }
        }
        if sources.isEmpty {
            sources.append(.standaloneSunshine)
        }
        return Array(Set(sources)).sorted { $0.rawValue < $1.rawValue }
    }

    private func bestTitleMatch(
        for sunshine: SunshineGame,
        in canonicalDatabase: [GameInfo]
    ) -> (game: GameInfo, score: Double, source: MatchSource)? {
        let target = normalizedTitle(sunshine.title)
        guard !target.isEmpty else { return nil }

        var best: (game: GameInfo, score: Double, source: MatchSource)?
        for game in canonicalDatabase {
            let candidate = normalizedTitle(game.title)
            guard !candidate.isEmpty else { continue }

            let titleScore: Double
            let source: MatchSource
            if candidate == target {
                titleScore = 0.88
                source = .exactTitle
            } else {
                titleScore = diceCoefficient(target, candidate)
                source = .fuzzyTitle
            }

            let commandBonus = commandPathBonus(sunshine: sunshine, normalizedCandidate: candidate)
            let score = min(0.94, titleScore + commandBonus)
            if best == nil || score > best!.score {
                best = (game, score, commandBonus > 0 ? .commandPath : source)
            }
        }
        return best
    }

    private func commandPathBonus(sunshine: SunshineGame, normalizedCandidate: String) -> Double {
        let haystack = [sunshine.launchCommand, sunshine.workingDirectory, sunshine.imagePath]
            .compactMap { $0 }
            .map(normalizedTitle)
            .joined(separator: " ")
        guard !haystack.isEmpty else { return 0 }
        if haystack.contains(normalizedCandidate) {
            return 0.08
        }
        let candidateWords = Set(normalizedCandidate.split(separator: " ").map(String.init).filter { $0.count > 2 })
        guard !candidateWords.isEmpty else { return 0 }
        let hitCount = candidateWords.filter { haystack.contains($0) }.count
        return hitCount >= max(1, candidateWords.count / 2) ? 0.04 : 0
    }

    private func platformHint(from sunshine: SunshineGame) -> String? {
        let haystack = [sunshine.launchCommand, sunshine.workingDirectory, sunshine.imagePath]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        if haystack.contains("ryujinx") || haystack.contains("yuzu") || haystack.contains("switch") {
            return "Nintendo Switch"
        }
        if haystack.contains("cemu") || haystack.contains("wiiu") || haystack.contains("wii u") {
            return "Nintendo Wii U"
        }
        if haystack.contains("dolphin") || haystack.contains("gamecube") {
            return "Nintendo GameCube"
        }
        if haystack.contains("pcsx2") || haystack.contains("ps2") {
            return "PlayStation 2"
        }
        if haystack.contains("rpcs3") || haystack.contains("ps3") {
            return "PlayStation 3"
        }
        if haystack.contains("xenia") || haystack.contains("xbox360") {
            return "Xbox 360"
        }
        if haystack.contains("retroarch") {
            return "Retro"
        }
        if haystack.contains("mame") {
            return "Arcade"
        }
        if haystack.contains("snes9x") || haystack.contains("snes") {
            return "Super Nintendo"
        }
        if haystack.contains("mgba") || haystack.contains("gba") {
            return "Game Boy Advance"
        }
        return nil
    }

    private func externalIdsFromSelectedCover(_ sunshine: SunshineGame) -> ExternalGameIds {
        let candidates = selectedCoverIdentityCandidates(from: sunshine)
        var ids = ExternalGameIds()
        for candidate in candidates {
            let lower = candidate.lowercased()
            if ids.gameDBId == nil,
               coverPathLooksLikeSunshineArtwork(candidate),
               let gameDBKey = gameDBKeyFromCoverFilename(candidate) {
                ids.gameDBId = gameDBKey
                if ids.igdbId == nil {
                    ids.igdbId = igdbIdFromGameDBKey(gameDBKey)
                }
            }
            if lower.contains("igdb"), ids.igdbId == nil {
                let igdbId = firstCapture(in: candidate, patterns: [
                    #"(?i)igdb[^0-9a-zA-Z]{0,4}([0-9]{2,12})"#,
                    #"(?i)(?:^|[^0-9a-zA-Z])igdb([0-9]{2,12})(?:[^0-9a-zA-Z]|$)"#
                ])
                ids.igdbId = igdbId
                if let igdbId,
                   ids.gameDBId == nil,
                   coverPathLooksLikeSunshineArtwork(candidate) {
                    ids.gameDBId = "igdb_\(igdbId)"
                }
            }
            if (lower.contains("gamedb") || lower.contains("game-db") || lower.contains("thegamesdb")),
               ids.gameDBId == nil {
                ids.gameDBId = firstCapture(in: candidate, patterns: [
                    #"(?i)(?:game-db|gamedb|thegamesdb)[^0-9a-zA-Z]{0,4}([0-9]{2,12})"#,
                    #"(?i)(?:^|[^0-9a-zA-Z])(?:gdb|tgdb)([0-9]{2,12})(?:[^0-9a-zA-Z]|$)"#
                ])
            }
            if ids.igdbId == nil,
               coverPathLooksLikeSunshineArtwork(candidate),
               let filenameId = numericIdentityFromCoverFilename(candidate) {
                ids.igdbId = filenameId
            }
        }
        return ids
    }

    private func selectedCoverHasNumericFilenameIdentity(_ sunshine: SunshineGame) -> Bool {
        selectedCoverIdentityCandidates(from: sunshine)
            .contains { coverPathLooksLikeSunshineArtwork($0) && numericIdentityFromCoverFilename($0) != nil }
    }

    private func selectedCoverIdentityCandidates(from sunshine: SunshineGame) -> [String] {
        var candidates: [String] = []
        if let imagePath = sunshine.imagePath, !isCloudNowCachedSunshineAsset(imagePath) {
            candidates.append(imagePath)
        }
        if let coverUrl = sunshine.boxArtUrl, !isCloudNowCachedSunshineAsset(coverUrl) {
            candidates.append(coverUrl)
        }
        for key in selectedCoverRawFieldKeys {
            guard let value = sunshine.rawFields[key],
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !isCloudNowCachedSunshineAsset(value) else {
                continue
            }
            candidates.append(value)
        }
        return Array(Set(candidates))
    }

    private var selectedCoverRawFieldKeys: [String] {
        [
            "ImagePath",
            "CoverPath",
            "BoxArtPath",
            "PosterPath",
            "AssetPath",
            "ArtworkPath",
            "IconPath",
            "image-path",
            "cover",
            "boxart",
            "boxArt",
            "poster",
            "artwork",
            "icon"
        ]
    }

    private func isCloudNowCachedSunshineAsset(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("/CloudNow/SunshineAssets/")
    }

    private func coverPathLooksLikeSunshineArtwork(_ value: String) -> Bool {
        let lower = value.lowercased()
        let providerClues = ["sunshine", "igdb", "gamedb", "game-db", "thegamesdb"]
        let artworkClues = ["cover", "boxart", "box-art", "poster", "artwork", "image", "cache"]
        return providerClues.contains { lower.contains($0) } || artworkClues.contains { lower.contains($0) }
    }

    private func numericIdentityFromCoverFilename(_ value: String) -> String? {
        let filename = coverFilename(from: value)
        let stem = filename.replacingOccurrences(
            of: #"\.[A-Za-z0-9]{2,5}$"#,
            with: "",
            options: .regularExpression
        )
        let matches = captures(in: stem, pattern: #"(?<![0-9])([0-9]{2,12})(?![0-9])"#)
            .filter { !commonArtworkSizeNumbers.contains($0) }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private func coverFilename(from value: String) -> String {
        if let url = URL(string: value), let last = url.pathComponents.last, !last.isEmpty {
            return last
        }
        return (value as NSString).lastPathComponent
    }

    private func gameDBKeyFromCoverFilename(_ value: String) -> String? {
        let stem = coverFilename(from: value)
            .replacingOccurrences(of: #"\.[A-Za-z0-9]{2,5}$"#, with: "", options: .regularExpression)
        guard let provider = firstCapture(in: stem, patterns: [#"(?i)^([a-z][a-z0-9]*)[_-][A-Za-z0-9._-]+$"#]),
              let identifier = firstCapture(in: stem, patterns: [#"(?i)^[a-z][a-z0-9]*[_-]([A-Za-z0-9._-]+)$"#]) else {
            return nil
        }
        let normalizedProvider: String
        switch provider.lowercased() {
        case "igdb", "steam", "gog", "lutris":
            normalizedProvider = provider.lowercased()
        case "egs", "epic":
            normalizedProvider = "epic"
        case "tgdb", "thegamesdb", "gamedb":
            normalizedProvider = "gamedb"
        default:
            return nil
        }
        return "\(normalizedProvider)_\(identifier)"
    }

    private func igdbIdFromGameDBKey(_ value: String) -> String? {
        firstCapture(in: value, patterns: [#"(?i)^igdb[_-]([0-9]{1,12})$"#])
    }

    private var commonArtworkSizeNumbers: Set<String> {
        ["64", "128", "256", "512", "600", "720", "1080", "1200", "1440", "1920", "2160", "3840"]
    }

    private func externalIdsFromVariants(_ variants: [GameVariant]) -> ExternalGameIds {
        var ids = ExternalGameIds()
        for variant in variants {
            switch variant.appStore {
            case "STEAM":
                if variant.id.allSatisfy(\.isNumber) {
                    ids.steamAppId = ids.steamAppId ?? variant.id
                }
            case "XBOX", "MICROSOFT":
                ids.xboxId = ids.xboxId ?? variant.id
            case "EPIC_GAMES_STORE":
                ids.epicId = ids.epicId ?? variant.id
            default:
                break
            }
        }
        return ids
    }

    private func launchOptions(from matchedGame: GameInfo?) -> [LaunchOption] {
        guard let matchedGame else { return [] }
        return matchedGame.variants.map { variant in
            LaunchOption(
                id: variant.id,
                providerID: .geforceNow,
                providerGameID: variant.appId ?? variant.id,
                title: matchedGame.title,
                launchCommand: nil,
                workingDirectory: nil,
                hostUniqueId: nil,
                isPreferred: false
            )
        }
    }

    private func deduped(_ games: [GameInfo]) -> [GameInfo] {
        var seen = Set<String>()
        return games.filter { seen.insert($0.id).inserted }
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

    private func firstCapture(in value: String, patterns: [String]) -> String? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            guard let match = regex.firstMatch(in: value, range: range), match.numberOfRanges > 1 else {
                continue
            }
            guard let captureRange = Range(match.range(at: 1), in: value) else { continue }
            return String(value[captureRange])
        }
        return nil
    }

    private func captures(in value: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: 1), in: value) else {
                return nil
            }
            return String(value[captureRange])
        }
    }
}

extension GameInfo {
    var isSunshineGame: Bool {
        id.hasPrefix("sunshine:") || variants.contains { $0.appStore == "SUNSHINE" }
    }

    var isReservedSunshinePowerApp: Bool {
        guard isSunshineGame else { return false }
        switch title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sleep", "shutdown bc-250": return true
        default: return false
        }
    }

    var sunshineAppId: String? {
        if id.hasPrefix("sunshine:") {
            return String(id.dropFirst("sunshine:".count))
        }
        return variants.first { $0.appStore == "SUNSHINE" }?.appId
    }
}

extension GameInfo {
    func unifiedGame(isActive: Bool = false) -> UnifiedGame {
        UnifiedGame(
            providerID: .geforceNow,
            providerGameID: id,
            title: title,
            boxArtUrl: boxArtUrl,
            heroBannerUrl: heroBannerUrl,
            availability: isActive ? .active : (isInLibrary ? .ready : .available),
            sourceDetail: variants.first?.storeName ?? GameProviderID.geforceNow.shortName
        )
    }
}
