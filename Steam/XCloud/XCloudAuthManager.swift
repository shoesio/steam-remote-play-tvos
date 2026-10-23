import Foundation
import Observation
import Security

@MainActor
@Observable
final class XCloudAuthManager {
    enum Phase: Equatable {
        case signedOut
        case requestingCode
        case waitingForUser(XCloudDeviceCodeViewState)
        case exchangingTokens
        case signedIn
        case failed(String)
    }

    struct XCloudDeviceCodeViewState: Equatable {
        let code: String
        let verificationURL: String
        let directURL: String?
    }

    private(set) var phase: Phase = .signedOut
    private(set) var credentials: XCloudCredentials?
    private var loginTask: Task<Void, Never>?

    private let service = "com.owenselles.CloudNow.xcloud"
    private let account = "microsoft-credentials"

    var isSignedIn: Bool { credentials != nil }

    init() {
        credentials = loadCredentials()
        phase = credentials == nil ? .signedOut : .signedIn
    }

    func signIn() {
        loginTask?.cancel()
        loginTask = Task {
            do {
                phase = .requestingCode
                let code = try await XCloudAuthAPI.requestDeviceCode()
                phase = .waitingForUser(.init(
                    code: code.userCode,
                    verificationURL: code.verificationURL,
                    directURL: code.directVerificationURL
                ))
                let oauth = try await XCloudAuthAPI.pollForToken(code)
                phase = .exchangingTokens
                let resolved = try await XCloudAuthAPI.makeCredentials(
                    accessToken: oauth.accessToken,
                    refreshToken: oauth.refreshToken,
                    expiresIn: oauth.expiresIn
                )
                credentials = resolved
                try saveCredentials(resolved)
                phase = .signedIn
            } catch is CancellationError {
                phase = credentials == nil ? .signedOut : .signedIn
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        loginTask?.cancel()
        loginTask = nil
        phase = credentials == nil ? .signedOut : .signedIn
    }

    func signOut() {
        cancelSignIn()
        credentials = nil
        deleteCredentials()
        phase = .signedOut
    }

    func resolvedCredentials() async throws -> XCloudCredentials {
        guard var current = credentials else { throw XCloudError.notSignedIn }
        if !current.streamTokenIsFresh || current.f2pToken == nil {
            let refreshed = try await XCloudAuthAPI.refreshCredentials(refreshToken: current.refreshToken)
            current = refreshed
            credentials = refreshed
            try saveCredentials(refreshed)
        }
        return current
    }

    func longPlayToken() async throws -> String {
        guard let refresh = credentials?.refreshToken else { throw XCloudError.notSignedIn }
        return try await XCloudAuthAPI.longPlayToken(refreshToken: refresh)
    }

    private func loadCredentials() -> XCloudCredentials? {
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
        return try? JSONDecoder().decode(XCloudCredentials.self, from: data)
    }

    private func saveCredentials(_ value: XCloudCredentials) throws {
        let data = try JSONEncoder().encode(value)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var insert = query
        insert[kSecValueData as String] = data
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw XCloudError.invalidResponse("Could not save Xbox credentials (\(status)).") }
    }

    private func deleteCredentials() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private enum XCloudAuthAPI {
    struct OAuthToken {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }

    private static let clientID = "1f907974-e22b-4810-a9de-d9647380c97e"
    private static let scopes = "xboxlive.signin openid profile offline_access"
    private static let lptScope = "service::http://Passport.NET/purpose::PURPOSE_XBOX_CLOUD_CONSOLE_TRANSFER_TOKEN"

    static func requestDeviceCode() async throws -> XCloudDeviceCode {
        let data = try await formPOST(
            "https://login.microsoftonline.com/consumers/oauth2/v2.0/devicecode",
            fields: ["client_id": clientID, "scope": scopes]
        )
        let json = try dictionary(data)
        guard let deviceCode = json["device_code"] as? String,
              let userCode = json["user_code"] as? String,
              let verification = json["verification_uri"] as? String else {
            throw XCloudError.invalidResponse("Missing device sign-in fields.")
        }
        return XCloudDeviceCode(
            deviceCode: deviceCode,
            userCode: userCode,
            verificationURL: verification,
            directVerificationURL: json["verification_uri_complete"] as? String,
            expiresIn: json["expires_in"] as? Int ?? 900,
            interval: json["interval"] as? Int ?? 5
        )
    }

    static func pollForToken(_ code: XCloudDeviceCode) async throws -> OAuthToken {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        while Date() < deadline {
            try await Task.sleep(for: .seconds(max(code.interval, 1)))
            do {
                return try await oauthToken(fields: [
                    "client_id": clientID,
                    "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                    "device_code": code.deviceCode
                ])
            } catch XCloudError.authorizationPending {
                continue
            }
        }
        throw XCloudError.authorizationExpired
    }

    static func refreshCredentials(refreshToken: String) async throws -> XCloudCredentials {
        let oauth = try await oauthToken(fields: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": scopes
        ])
        return try await makeCredentials(
            accessToken: oauth.accessToken,
            refreshToken: oauth.refreshToken.isEmpty ? refreshToken : oauth.refreshToken,
            expiresIn: oauth.expiresIn
        )
    }

    static func makeCredentials(accessToken: String, refreshToken: String, expiresIn: Int) async throws -> XCloudCredentials {
        let userToken = try await xboxToken(
            url: "https://user.auth.xboxlive.com/user/authenticate",
            body: [
                "RelyingParty": "http://auth.xboxlive.com",
                "TokenType": "JWT",
                "Properties": [
                    "AuthMethod": "RPS",
                    "SiteName": "user.auth.xboxlive.com",
                    "RpsTicket": "d=\(accessToken)"
                ]
            ]
        )
        let xsts = try await xboxToken(
            url: "https://xsts.auth.xboxlive.com/xsts/authorize",
            body: [
                "RelyingParty": "http://gssv.xboxlive.com/",
                "TokenType": "JWT",
                "Properties": ["SandboxId": "RETAIL", "UserTokens": [userToken]]
            ]
        )
        async let gamePassLogin = streamLogin(xstsToken: xsts, offering: "xgpuweb")
        async let freeToPlayLogin = try? streamLogin(xstsToken: xsts, offering: "xgpuwebf2p")
        let primary = try await gamePassLogin
        let supplementary = await freeToPlayLogin
        guard !primary.token.isEmpty else {
            throw XCloudError.invalidResponse("Missing xCloud stream token. Is Game Pass Ultimate active?")
        }
        return XCloudCredentials(
            accessToken: accessToken,
            refreshToken: refreshToken,
            accessTokenExpiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            gsToken: primary.token,
            streamHost: primary.host,
            gsTokenExpiresAt: Date().addingTimeInterval(55 * 60),
            f2pToken: supplementary?.token,
            f2pHost: supplementary?.host
        )
    }

    private static func streamLogin(xstsToken: String, offering: String) async throws -> (token: String, host: String) {
        let canonicalHost = "https://\(offering).gssv-play-prod.xboxlive.com"
        let data = try await jsonPOST(
            "\(canonicalHost)/v2/login/user",
            body: ["token": xstsToken, "offeringId": offering],
            headers: ["x-gssv-client": "XboxComBrowser"]
        )
        let json = try dictionary(data)
        guard let token = json["gsToken"] as? String else {
            throw XCloudError.invalidResponse("Missing \(offering) stream token.")
        }
        let settings = json["offeringSettings"] as? [String: Any]
        let regions = settings?["regions"] as? [[String: Any]] ?? []
        let region = regions.first(where: { $0["isDefault"] as? Bool == true }) ?? regions.first
        let host = (region?["baseUri"] as? String) ?? canonicalHost
        return (token, host.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    static func longPlayToken(refreshToken: String) async throws -> String {
        let data = try await formPOST("https://login.live.com/oauth20_token.srf", fields: [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": lptScope
        ])
        let json = try dictionary(data)
        guard let token = json["access_token"] as? String else {
            throw XCloudError.invalidResponse("Missing cloud transfer token.")
        }
        return token
    }

    private static func oauthToken(fields: [String: String]) async throws -> OAuthToken {
        let data: Data
        do {
            data = try await formPOST("https://login.microsoftonline.com/consumers/oauth2/v2.0/token", fields: fields)
        } catch XCloudError.server(_, let body) {
            if body.contains("authorization_pending") { throw XCloudError.authorizationPending }
            if body.contains("expired_token") || body.contains("authorization_declined") { throw XCloudError.authorizationExpired }
            throw XCloudError.invalidResponse(body)
        }
        let json = try dictionary(data)
        guard let access = json["access_token"] as? String else { throw XCloudError.invalidResponse("Missing OAuth access token.") }
        return OAuthToken(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String ?? "",
            expiresIn: json["expires_in"] as? Int ?? 3600
        )
    }

    private static func xboxToken(url: String, body: [String: Any]) async throws -> String {
        let data = try await jsonPOST(url, body: body, headers: ["x-xbl-contract-version": "1"])
        guard let token = try dictionary(data)["Token"] as? String else {
            throw XCloudError.invalidResponse("Missing Xbox authorization token.")
        }
        return token
    }

    private static func formPOST(_ url: String, fields: [String: String]) async throws -> Data {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return try await perform(request)
    }

    private static func jsonPOST(_ url: String, body: [String: Any], headers: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request)
    }

    private static func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw XCloudError.server((response as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    private static func dictionary(_ data: Data) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCloudError.invalidResponse("Invalid JSON.")
        }
        return json
    }
}
