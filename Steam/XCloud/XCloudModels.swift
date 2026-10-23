import Foundation

enum XCloudTitleFormatter {
    nonisolated static func displayTitle(_ value: String) -> String {
        let withoutPrefix = value.replacingOccurrences(
            of: #"(?i)^x-?box\s+title\s*[:\-–—]?\s*"#,
            with: "",
            options: .regularExpression
        )
        let cleaned = withoutPrefix
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return titleCaseFallback(cleaned)
    }

    private nonisolated static func titleCaseFallback(_ value: String) -> String {
        let letters = value.unicodeScalars.filter(CharacterSet.letters.contains)
        guard !letters.isEmpty,
              letters.allSatisfy({ CharacterSet.uppercaseLetters.contains($0) }) else {
            return value
        }
        let preserved = Set(["EA", "FC", "F1", "GTA", "LEGO", "MLB", "NBA", "NFL", "NHL", "PGA", "UFC", "WWE", "2K", "DOOM"])
        return value.split(separator: " ").map { word in
            let upper = word.uppercased()
            if preserved.contains(upper) || upper.range(of: #"^[IVX]+$"#, options: .regularExpression) != nil {
                return upper
            }
            return word.lowercased().capitalized
        }.joined(separator: " ")
    }
}

struct XCloudGame: Identifiable, Hashable, Codable, Sendable {
    let id: String
    let productID: String
    let title: String
    let supportsController: Bool
    let hasEntitlement: Bool
    var boxArtURL: String?
    var heroArtURL: String?
    var providerMetadata: GameProviderMetadata? = nil

    var gameInfo: GameInfo {
        GameInfo(
            id: "xcloud:\(id)",
            title: title,
            boxArtUrl: boxArtURL,
            heroBannerUrl: heroArtURL,
            isInLibrary: true,
            variants: [
                GameVariant(id: "xcloud:\(id)", appStore: "XCLOUD", appId: id, isOwned: true)
            ],
            canonicalId: productID.isEmpty ? nil : "xbox:\(productID)",
            matchConfidence: 1,
            matchSource: "xcloudEntitlement",
            providerMetadata: providerMetadata
        )
    }
}

struct XCloudHomePlaylists: Codable, Sendable {
    var newOnXCloud: [XCloudGame]
    var mostPopular: [XCloudGame]

    static let empty = XCloudHomePlaylists(newOnXCloud: [], mostPopular: [])
}

extension GameInfo {
    var isXCloudGame: Bool {
        id.hasPrefix("xcloud:") || variants.contains { $0.appStore == "XCLOUD" }
    }

    var xcloudTitleID: String? {
        if id.hasPrefix("xcloud:") { return String(id.dropFirst("xcloud:".count)) }
        return variants.first { $0.appStore == "XCLOUD" }?.appId
    }
}

struct XCloudCredentials: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var accessTokenExpiresAt: Date
    var gsToken: String
    var streamHost: String
    var gsTokenExpiresAt: Date
    var f2pToken: String?
    var f2pHost: String?

    var canRefresh: Bool { !refreshToken.isEmpty }
    var streamTokenIsFresh: Bool { gsTokenExpiresAt > Date().addingTimeInterval(120) }
}

struct XCloudDeviceCode: Sendable {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let directVerificationURL: String?
    let expiresIn: Int
    let interval: Int
}

struct XCloudSession: Sendable {
    let path: String
    let titleID: String
}

enum XCloudError: LocalizedError {
    case notSignedIn
    case authorizationPending
    case authorizationExpired
    case invalidResponse(String)
    case server(Int, String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "Sign in to Xbox before using cloud gaming."
        case .authorizationPending: return "Waiting for Microsoft sign-in."
        case .authorizationExpired: return "The Microsoft sign-in code expired."
        case .invalidResponse(let message): return "Xbox returned an unexpected response: \(message)"
        case .server(let status, let message): return "Xbox service error \(status): \(message)"
        case .timedOut(let operation): return "Xbox timed out while \(operation)."
        }
    }
}
