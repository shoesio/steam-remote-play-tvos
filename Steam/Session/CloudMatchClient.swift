import Foundation

// MARK: - CloudMatch Headers

private func gfnHeaders(token: String, clientId: String, deviceId: String, includeOrigin: Bool = true) -> [String: String] {
    var h: [String: String] = [
        "User-Agent": NVIDIAAuth.userAgent,
        "Authorization": "GFNJWT \(token)",
        "Content-Type": "application/json",
        "nv-browser-type": "CHROME",
        "nv-client-id": clientId,
        "nv-client-streamer": "WEBRTC",
        "nv-client-type": "BROWSER",
        "nv-client-version": "2.0.85.133",
        "nv-device-make": "APPLE",
        "nv-device-model": "UNKNOWN",
        "nv-device-os": "MACOS",
        "nv-device-type": "DESKTOP",
        "x-device-id": deviceId,
    ]
    if includeOrigin {
        h["Origin"] = "https://play.geforcenow.com"
        h["Referer"] = "https://play.geforcenow.com/"
    }
    return h
}

// MARK: - CloudMatch Response Types

private struct CloudMatchResponse: Decodable {
    let session: SessionPayload
    struct SessionPayload: Decodable {
        let sessionId: String
        let status: Int
        let gpuType: String?
        let queuePosition: Int?
        let seatSetupStep: Int?
        let connectionInfo: [ConnectionInfo]?
        let iceServerConfiguration: IceServerConfig?
        let sessionControlInfo: SessionControlInfo?
        let sessionRequestData: SessionRequestDataPayload?

        struct ConnectionInfo: Decodable {
            let usage: Int
            let ip: AnyCodableString?
            let port: Int
            let resourcePath: String?
        }

        struct IceServerConfig: Decodable {
            let iceServers: [RawIceServer]?
            struct RawIceServer: Decodable {
                let urls: AnyCodableStringArray
                let username: String?
                let credential: String?
            }
        }

        struct SessionControlInfo: Decodable {
            let ip: AnyCodableString?
        }

        struct SessionRequestDataPayload: Decodable {
            let metaData: [MetaDataItem]?

            struct MetaDataItem: Decodable {
                let key: String
                let value: String?
            }
        }
    }
}

// Ad action codes sent to CloudMatch
enum AdAction: Int {
    case start  = 1
    case pause  = 2
    case resume = 3
    case finish = 4
    case cancel = 5
}

// GFN API returns ip as a string, array of strings, 32-bit integer, or {"value": ...} object
private struct AnyCodableString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        // Nested object: {"value": "80.84.170.152"} or {"value": 1345682432}
        struct Nested: Decodable { let value: AnyCodableString? }
        if let nested = try? Nested(from: decoder), let v = nested.value?.value {
            value = v
            return
        }
        // Integer IP (32-bit big-endian, e.g. 1345682432 → "80.84.170.152")
        if let intVal = try? UInt32(from: decoder) {
            let b1 = (intVal >> 24) & 0xFF
            let b2 = (intVal >> 16) & 0xFF
            let b3 = (intVal >> 8)  & 0xFF
            let b4 =  intVal        & 0xFF
            value = "\(b1).\(b2).\(b3).\(b4)"
            return
        }
        // String array or plain string
        if let arr = try? [String].init(from: decoder) {
            value = arr.first
        } else {
            value = try? String(from: decoder)
        }
    }
}

private struct AnyCodableStringArray: Decodable {
    let values: [String]
    init(from decoder: Decoder) throws {
        if let arr = try? [String].init(from: decoder) {
            values = arr
        } else if let single = try? String(from: decoder) {
            values = [single]
        } else {
            values = []
        }
    }
}

private struct AnyCodablePlainString: Decodable {
    let value: String?

    init(from decoder: Decoder) throws {
        if let stringValue = try? String(from: decoder) {
            value = stringValue
        } else if let intValue = try? Int(from: decoder) {
            value = String(intValue)
        } else {
            value = nil
        }
    }
}

private struct AnyCodableInt: Decodable {
    let value: Int?

    init(from decoder: Decoder) throws {
        if let intValue = try? Int(from: decoder) {
            value = intValue
        } else if let stringValue = try? String(from: decoder) {
            value = Int(stringValue)
        } else {
            value = nil
        }
    }
}

private struct GetSessionsResponse: Decodable {
    let requestStatus: RequestStatus?
    let sessions: [SessionEntry]?
    struct RequestStatus: Decodable {
        let statusCode: AnyCodableInt?
        let statusDescription: String?
    }
    struct SessionEntry: Decodable {
        let sessionId: String
        let status: AnyCodableInt
        let sessionRequestData: SessionRequestData?
        let connectionInfo: [ConnEntry]?
        let sessionControlInfo: CtrlEntry?

        struct SessionRequestData: Decodable { let appId: AnyCodablePlainString? }
        struct ConnEntry: Decodable { let ip: AnyCodableString?; let port: Int?; let usage: Int? }
        struct CtrlEntry: Decodable { let ip: AnyCodableString? }
    }
}

// MARK: - Session Request Body

private func buildSessionRequestData(
    appId: String,
    internalTitle: String?,
    settings: StreamSettings,
    accountLinked: Bool,
    deviceHashId: String,
    subSessionId: String? = nil
) -> [String: Any] {
    let resolutionParts = settings.resolution.split(separator: "x")
    let width = Int(resolutionParts.first ?? "1920") ?? 1920
    let height = Int(resolutionParts.last ?? "1080") ?? 1080
    let tzOffset = -TimeZone.current.secondsFromGMT() * 1000
    let isHdr = settings.colorQuality == .hdr10bit

    return [
            "appId": appId,
            "internalTitle": internalTitle ?? NSNull(),
            "availableSupportedControllers": [],
            "networkTestSessionId": NSNull(),
            "parentSessionId": NSNull(),
            "clientIdentification": "GFN-PC",
            "deviceHashId": deviceHashId,
            "clientVersion": "30.0",
            "sdkVersion": "1.0",
            "streamerVersion": 1,
            "clientPlatformName": "mac",
            "clientRequestMonitorSettings": [[
                "widthInPixels": width,
                "heightInPixels": height,
                "framesPerSecond": settings.fps,
                "sdrHdrMode": isHdr ? 1 : 0,
                "displayData": [
                    "desiredContentMaxLuminance": isHdr ? 1000 : 0,
                    "desiredContentMinLuminance": 0,
                    "desiredContentMaxFrameAverageLuminance": isHdr ? 500 : 0,
                ],
                "dpi": 100,
            ]],
            "useOps": true,
            "audioMode": 2,
            "metaData": [
                ["key": "SubSessionId", "value": subSessionId ?? UUID().uuidString],
                ["key": "wssignaling", "value": "1"],
                ["key": "GSStreamerType", "value": "WebRTC"],
                ["key": "networkType", "value": "Unknown"],
                ["key": "ClientImeSupport", "value": "0"],
                ["key": "clientPhysicalResolution", "value": "{\"horizontalPixels\":\(width),\"verticalPixels\":\(height)}"],
                ["key": "surroundAudioInfo", "value": "2"],
            ],
            "sdrHdrMode": isHdr ? 1 : 0,
            "clientDisplayHdrCapabilities": isHdr ? [
                "version": 1,
                "hdrEdrSupportedFlagsInUint32": 1,
                "staticMetadataDescriptorId": 0,
            ] : NSNull(),
            "surroundAudioInfo": 0,
            "remoteControllersBitmap": 0,
            "clientTimezoneOffset": tzOffset,
            "enhancedStreamMode": 1,
            "appLaunchMode": 1,
            "secureRTSPSupported": false,
            "partnerCustomData": "",
            "accountLinked": accountLinked,
            "enablePersistingInGameSettings": true,
            "userAge": 26,
            "requestedStreamingFeatures": [
                "reflex": settings.fps >= 120,
                "bitDepth": settings.colorQuality.bitDepth,
                "cloudGsync": false,
                "enabledL4S": settings.enableL4S,
                "mouseMovementFlags": 0,
                "trueHdr": isHdr,
                "supportedHidDevices": 0,
                "profile": 0,
                "fallbackToLogicalResolution": false,
                "hidDevices": NSNull(),
                "chromaFormat": settings.colorQuality.chromaFormat,
                "prefilterMode": 0,
                "prefilterSharpness": 0,
                "prefilterNoiseReduction": 0,
                "hudStreamingMode": 0,
                "sdrColorSpace": 2,
                "hdrColorSpace": isHdr ? 4 : 0,
            ],
    ]
}

private func buildSessionRequestBody(_ input: SessionCreateRequest) -> [String: Any] {
    [
        "sessionRequestData": buildSessionRequestData(
            appId: input.appId,
            internalTitle: input.internalTitle,
            settings: input.settings,
            accountLinked: input.accountLinked,
            deviceHashId: CloudMatchClient.persistentDeviceHashId
        )
    ]
}

// MARK: - Signaling URL Resolution

private func resolveSignalingUrl(serverIp: String, resourcePath: String) -> String {
    if resourcePath.hasPrefix("rtsps://") || resourcePath.hasPrefix("rtsp://") {
        let withoutScheme = resourcePath.hasPrefix("rtsps://")
            ? String(resourcePath.dropFirst("rtsps://".count))
            : String(resourcePath.dropFirst("rtsp://".count))
        let host = withoutScheme.components(separatedBy: ":").first?
                                .components(separatedBy: "/").first ?? ""
        if !host.isEmpty && !host.hasPrefix(".") {
            return "wss://\(host)/nvst/"
        }
    }
    if resourcePath.hasPrefix("wss://") { return resourcePath }
    if resourcePath.hasPrefix("/") { return "wss://\(serverIp):443\(resourcePath)" }
    return "wss://\(serverIp):443/nvst/"
}

// MARK: - CloudMatchClient

actor CloudMatchClient {
    private let urlSession = URLSession.shared

    nonisolated static var persistentClientId: String {
        persistedIdentifier(forKey: "gfn.persistentClientId")
    }

    nonisolated static var persistentDeviceId: String {
        persistedIdentifier(forKey: "gfn.persistentDeviceId")
    }

    nonisolated static var persistentDeviceHashId: String {
        persistedIdentifier(forKey: "gfn.persistentDeviceHashId")
    }

    nonisolated private static func persistedIdentifier(forKey key: String) -> String {
        if let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty {
            return saved
        }
        let value = UUID().uuidString.uppercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }

    private func requestBodyPreview(_ body: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted]),
              let raw = String(data: data, encoding: .utf8)
        else { return "<unprintable body>" }
        return raw.count > 1_500 ? String(raw.prefix(1_500)) + "..." : raw
    }

    private func responseBodyPreview(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? "<non-utf8 \(data.count) bytes>"
        return raw.count > 600 ? String(raw.prefix(600)) + "..." : raw
    }

    private func decodeCloudMatchResponse(from data: Data, context: String) throws -> CloudMatchResponse {
        do {
            return try JSONDecoder().decode(CloudMatchResponse.self, from: data)
        } catch {
            let preview = responseBodyPreview(data)
            throw CloudMatchError.sessionCreateFailed("\(context) returned an unexpected response: \(preview)")
        }
    }

    private func isLimitResponse(_ data: Data) -> Bool {
        let raw = String(data: data, encoding: .utf8)?.uppercased() ?? ""
        return raw.contains("SESSION_LIMIT_EXCEEDED")
            || raw.contains("REQUEST_LIMIT_EXCEEDED")
            || raw.contains("LIMIT_EXCEEDED")
    }

    // MARK: Create Session

    func createSession(_ input: SessionCreateRequest) async throws -> SessionInfo {
        let clientId = Self.persistentClientId
        let deviceId = Self.persistentDeviceId
        let base = input.streamingBaseUrl.map {
            $0.hasSuffix("/") ? String($0.dropLast()) : $0
        } ?? "https://prod.cloudmatchbeta.nvidiagrid.net"

        let params = URLComponents(string: "\(base)/v2/session")!.url!
            .appending(queryItems: [
                URLQueryItem(name: "keyboardLayout", value: input.settings.keyboardLayout),
                URLQueryItem(name: "languageCode", value: input.settings.gameLanguage),
            ])

        let body = buildSessionRequestBody(input)
        var request = URLRequest(url: params)
        request.httpMethod = "POST"
        for (k, v) in gfnHeaders(token: input.token, clientId: clientId, deviceId: deviceId, includeOrigin: true) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        print("[CloudMatch] createSession POST \(params.absoluteString)")
        print("[CloudMatch] createSession body \(requestBodyPreview(body))")
        let (data, resp) = try await urlSession.data(for: request)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        print("[CloudMatch] createSession response HTTP \(statusCode): \(responseBodyPreview(data))")
        guard statusCode == 200 else {
            if isLimitResponse(data),
               let payload = try? JSONDecoder().decode(CloudMatchResponse.self, from: data) {
                let existing = try toSessionInfo(
                    base: base,
                    payload: payload,
                    rawData: data,
                    clientId: clientId,
                    deviceId: deviceId
                )
                return try await claimSession(
                    sessionId: existing.sessionId,
                    serverIp: SessionInfo.isValidHost(existing.serverIp) ? existing.serverIp : nil,
                    token: input.token,
                    base: base,
                    appId: input.appId,
                    settings: input.settings
                )
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw CloudMatchError.sessionCreateFailed(msg)
        }
        let payload = try decodeCloudMatchResponse(from: data, context: "Create session")
        return try toSessionInfo(base: base, payload: payload, rawData: data, clientId: clientId, deviceId: deviceId)
    }

    // MARK: Poll Session

    private func pollSessionWithRawResponse(sessionId: String, token: String, base: String, serverIp: String?,
                                            clientId: String, deviceId: String) async throws -> (SessionInfo, Data) {
        let effectiveBase = serverIp.map { "https://\($0)" } ?? base
        let url = URL(string: "\(effectiveBase)/v2/session/\(sessionId)")!
        var request = URLRequest(url: url)
        for (k, v) in gfnHeaders(token: token, clientId: clientId, deviceId: deviceId, includeOrigin: false) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        print("[CloudMatch] pollSession GET \(url.absoluteString)")
        let (data, resp) = try await urlSession.data(for: request)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        print("[CloudMatch] pollSession response HTTP \(statusCode): \(responseBodyPreview(data))")
        guard statusCode == 200 else {
            if let payload = try? JSONDecoder().decode(CloudMatchResponse.self, from: data) {
                return (try toSessionInfo(
                    base: effectiveBase,
                    payload: payload,
                    rawData: data,
                    clientId: clientId,
                    deviceId: deviceId
                ), data)
            }
            throw CloudMatchError.sessionCreateFailed("Poll session failed: \(responseBodyPreview(data))")
        }
        let payload = try decodeCloudMatchResponse(from: data, context: "Poll session")
        return (try toSessionInfo(base: effectiveBase, payload: payload, rawData: data, clientId: clientId, deviceId: deviceId), data)
    }

    func pollSession(sessionId: String, token: String, base: String, serverIp: String?,
                     clientId: String, deviceId: String) async throws -> SessionInfo {
        let (info, _) = try await pollSessionWithRawResponse(
            sessionId: sessionId,
            token: token,
            base: base,
            serverIp: serverIp,
            clientId: clientId,
            deviceId: deviceId
        )
        return info
    }

    // MARK: Stop Session

    func stopSession(sessionId: String, token: String, base: String) async throws {
        let url = URL(string: "\(base)/v2/session/\(sessionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("GFNJWT \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(NVIDIAAuth.userAgent, forHTTPHeaderField: "User-Agent")
        _ = try await urlSession.data(for: request)
    }

    // MARK: Active Sessions

    func getActiveSessions(token: String, base: String) async throws -> [ActiveSessionInfo] {
        let url = URL(string: "\(base)/v2/session")!
        var request = URLRequest(url: url)
        let clientId = Self.persistentClientId
        let deviceId = Self.persistentDeviceId
        for (k, v) in gfnHeaders(token: token, clientId: clientId, deviceId: deviceId, includeOrigin: true) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        let (data, response) = try await urlSession.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudMatchError.sessionCreateFailed("Active sessions failed: \(responseBodyPreview(data))")
        }
        let resp: GetSessionsResponse
        do {
            resp = try JSONDecoder().decode(GetSessionsResponse.self, from: data)
        } catch {
            throw CloudMatchError.sessionCreateFailed("Active sessions returned an unexpected response: \(responseBodyPreview(data))")
        }

        return (resp.sessions ?? []).compactMap { entry -> ActiveSessionInfo? in
            guard let status = entry.status.value, status == 1 || status == 2 || status == 3 else { return nil }
            let appId = entry.sessionRequestData?.appId?.value
            let sigConn = entry.connectionInfo?.first { $0.usage == 14 && $0.ip?.value != nil }
                       ?? entry.connectionInfo?.first { $0.ip?.value != nil }
            let serverIp = sigConn?.ip?.value ?? entry.sessionControlInfo?.ip?.value
            let signalingUrl = serverIp.map { "wss://\($0):443/nvst/" }
            return ActiveSessionInfo(
                sessionId: entry.sessionId,
                status: status,
                appId: appId,
                serverIp: serverIp,
                signalingUrl: signalingUrl
            )
        }
    }

    // MARK: Claim / Resume Session

    /// Attaches to an existing session. True queue sessions are returned as-is;
    /// otherwise RESUME is sent to rebuild the stream endpoint.
    /// The caller should continue polling via pollSession() until the session is streaming.
    func claimSession(
        sessionId: String,
        serverIp: String?,
        token: String,
        base: String,
        appId: String?,
        accountLinked: Bool = true,
        settings: StreamSettings
    ) async throws -> SessionInfo {
        let clientId = Self.persistentClientId
        let deviceId = Self.persistentDeviceId
        let effectiveBase = serverIp.map { "https://\($0)" } ?? base

        // Pre-flight: get current session state and, where available, NVIDIA's
        // exact sessionRequestData. Reusing it makes RESUME less brittle.
        let (preflight, preflightData) = try await pollSessionWithRawResponse(
            sessionId: sessionId,
            token: token,
            base: base,
            serverIp: serverIp,
            clientId: clientId,
            deviceId: deviceId
        )

        // If still queuing, return as-is — caller polls from here.
        // Status 1 with queuePosition <= 1 is often an existing session that still needs RESUME.
        if preflight.isInQueue { return preflight }

        // Send RESUME PUT for ready sessions and for existing status-1 sessions
        // that are not actually waiting in queue.
        let resumeBase = SessionInfo.isValidHost(preflight.serverIp) ? "https://\(preflight.serverIp)" : effectiveBase
        var comps = URLComponents(string: "\(resumeBase)/v2/session/\(sessionId)")!
        comps.queryItems = [
            URLQueryItem(name: "keyboardLayout", value: settings.keyboardLayout),
            URLQueryItem(name: "languageCode", value: settings.gameLanguage),
        ]
        guard let url = comps.url else { throw CloudMatchError.sessionCreateFailed("Invalid resume URL") }
        let serverRequestData = extractSessionRequestData(from: preflightData)
        let body: [String: Any] = [
            "action": 2,
            "data": "RESUME",
            "sessionRequestData": serverRequestData ?? buildSessionRequestData(
                appId: appId ?? "",
                internalTitle: nil,
                settings: settings,
                accountLinked: accountLinked,
                deviceHashId: Self.persistentDeviceHashId,
                subSessionId: preflight.subSessionId
            ),
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in gfnHeaders(token: token, clientId: clientId, deviceId: deviceId, includeOrigin: true) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        print("[CloudMatch] claimSession PUT \(url.absoluteString)")
        print("[CloudMatch] claimSession body \(requestBodyPreview(body))")
        let (data, resp) = try await urlSession.data(for: request)
        let statusCode = (resp as? HTTPURLResponse)?.statusCode ?? 0
        print("[CloudMatch] claimSession response HTTP \(statusCode): \(responseBodyPreview(data))")
        guard statusCode == 200 else {
            if let payload = try? JSONDecoder().decode(CloudMatchResponse.self, from: data) {
                return try toSessionInfo(
                    base: resumeBase,
                    payload: payload,
                    rawData: data,
                    clientId: clientId,
                    deviceId: deviceId
                )
            }
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw CloudMatchError.sessionCreateFailed("Resume failed: \(msg)")
        }
        let payload = try decodeCloudMatchResponse(from: data, context: "Resume session")
        return try toSessionInfo(base: resumeBase, payload: payload, rawData: data,
                                 clientId: clientId, deviceId: deviceId)
    }

    // MARK: Private

    private func toSessionInfo(base: String, payload: CloudMatchResponse, rawData: Data, clientId: String, deviceId: String) throws -> SessionInfo {
        let s = payload.session
        let connections = s.connectionInfo ?? []
        let connInfoLog = connections.map { c -> String in
            let ipStr = c.ip.map { $0.value ?? "value_nil" } ?? "field_nil"
            return "usage=\(c.usage) ip=\(ipStr) port=\(c.port) path=\(c.resourcePath ?? "nil")"
        }.joined(separator: " | ")
        print("[CloudMatch] connectionInfo: \(connInfoLog)")

        // Diagnostic raw JSON dump (once per active session — status==2 or 3)
        if s.status == 2 || s.status == 3,
           let root = try? JSONSerialization.jsonObject(with: rawData) as? [String: Any],
           let sess = root["session"] as? [String: Any] {
            if let iceConfig = sess["iceServerConfiguration"] {
                if let iceData = try? JSONSerialization.data(withJSONObject: iceConfig, options: .prettyPrinted),
                   let iceStr = String(data: iceData, encoding: .utf8) {
                    print("[CloudMatch] iceServerConfiguration:\n\(iceStr)")
                } else {
                    print("[CloudMatch] iceServerConfiguration: \(iceConfig)")
                }
            } else {
                print("[CloudMatch] iceServerConfiguration: absent")
            }
            if let sci = sess["sessionControlInfo"] {
                print("[CloudMatch] sessionControlInfo: \(sci)")
            }
        }

        // Signaling server: usage=14
        let sigConn = connections.first { $0.usage == 14 && $0.ip?.value != nil }
                   ?? connections.first { $0.ip?.value != nil }
        let rawServerIp = sigConn?.ip?.value ?? s.sessionControlInfo?.ip?.value ?? ""
        let serverIp = SessionInfo.isValidHost(rawServerIp) ? rawServerIp : ""
        let resourcePath = sigConn?.resourcePath ?? "/nvst/"
        let signalingUrl = resolveSignalingUrl(serverIp: serverIp, resourcePath: resourcePath)

        // ICE servers
        let rawIceServers = s.iceServerConfiguration?.iceServers ?? []
        let iceServers = rawIceServers.isEmpty
            ? defaultIceServers()
            : rawIceServers.map { IceServer(urls: $0.urls.values, username: $0.username, credential: $0.credential) }

        // Media connection — priority: usage=2 → usage=17 → usage=14 highest-port (IP from resourcePath)
        let mediaConn = connections.first { $0.usage == 2 }
                     ?? connections.first { $0.usage == 17 }
        let media: MediaConnectionInfo? = mediaConn.flatMap { mc -> MediaConnectionInfo? in
            guard let ip = mc.ip?.value, mc.port > 0 else { return nil }
            guard SessionInfo.isValidHost(ip) else { return nil }
            return MediaConnectionInfo(ip: ip, port: mc.port)
        } ?? extractMediaFromUsage14(connections)
        print("[CloudMatch] mediaConnectionInfo: \(media.map { "\($0.ip):\($0.port)" } ?? "nil")")

        // Ad state — parse raw JSON for flexibility since ad schema varies
        let adState = extractAdState(from: rawData)
        let subSessionId = s.sessionRequestData?.metaData?.first { $0.key == "SubSessionId" }?.value

        return SessionInfo(
            sessionId: s.sessionId,
            subSessionId: subSessionId,
            status: s.status,
            zone: "",
            streamingBaseUrl: base,
            serverIp: serverIp,
            signalingServer: serverIp.contains(":") ? serverIp : "\(serverIp):443",
            signalingUrl: signalingUrl,
            gpuType: s.gpuType,
            queuePosition: s.queuePosition,
            seatSetupStep: s.seatSetupStep,
            iceServers: iceServers,
            mediaConnectionInfo: media,
            clientId: clientId,
            deviceId: deviceId,
            adState: adState
        )
    }

    private func extractSessionRequestData(from data: Data) -> [String: Any]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = root["session"] as? [String: Any],
              let requestData = session["sessionRequestData"] as? [String: Any] else {
            print("[CloudMatch] sessionRequestData absent in preflight; using generated RESUME payload")
            return nil
        }
        print("[CloudMatch] Reusing server-returned sessionRequestData for RESUME")
        return requestData
    }

    /// Parses ad state from the raw response JSON, handling schema variations across GFN API versions.
    private func extractAdState(from data: Data) -> SessionAdState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionObj = root["session"] as? [String: Any] else { return nil }

        // isAdsRequired lives in several possible places
        func bool(_ key: String, in obj: [String: Any]) -> Bool? {
            guard let v = obj[key] else { return nil }
            if let b = v as? Bool { return b }
            if let i = v as? Int { return i != 0 }
            return nil
        }

        let isAdsRequired = bool("sessionAdsRequired", in: sessionObj)
            ?? bool("isAdsRequired", in: sessionObj)
            ?? bool("isAdsRequired", in: (sessionObj["sessionProgress"] as? [String: Any]) ?? [:])
            ?? bool("isAdsRequired", in: (sessionObj["progressInfo"] as? [String: Any]) ?? [:])
            ?? false

        let isQueuePaused = bool("isQueuePaused", in: sessionObj)
            ?? bool("queuePaused", in: (sessionObj["opportunity"] as? [String: Any]) ?? [:])

        let gracePeriodSeconds = (sessionObj["opportunity"] as? [String: Any])?["gracePeriodSeconds"] as? Int

        let message = (sessionObj["opportunity"] as? [String: Any]).flatMap {
            ($0["message"] ?? $0["description"]) as? String
        }

        let adsRaw = sessionObj["sessionAds"] as? [[String: Any]] ?? []
        let ads: [SessionAdInfo] = adsRaw.enumerated().compactMap { idx, ad in
            let adId = (ad["adId"] as? String) ?? "ad-\(idx + 1)"
            let mediaFiles = (ad["adMediaFiles"] as? [[String: Any]] ?? []).compactMap { f -> SessionAdMediaFile? in
                let url = f["mediaFileUrl"] as? String
                let profile = f["encodingProfile"] as? String
                guard url != nil || profile != nil else { return nil }
                return SessionAdMediaFile(mediaFileUrl: url, encodingProfile: profile)
            }
            let adUrl = ad["adUrl"] as? String
            let mediaUrl = (ad["mediaUrl"] ?? ad["videoUrl"] ?? ad["url"]) as? String
            let lengthSeconds = (ad["adLengthInSeconds"] ?? ad["durationMs"]) as? Double
            return SessionAdInfo(adId: adId, adUrl: adUrl, mediaUrl: mediaUrl,
                                 adMediaFiles: mediaFiles, adLengthInSeconds: lengthSeconds)
        }

        // Only return an ad state if there's actually something to act on
        if !isAdsRequired, ads.isEmpty, isQueuePaused != true { return nil }

        return SessionAdState(
            isAdsRequired: isAdsRequired,
            isQueuePaused: isQueuePaused,
            gracePeriodSeconds: gracePeriodSeconds,
            message: message,
            ads: ads
        )
    }

    // MARK: Report Ad Event

    func reportAdEvent(
        sessionId: String,
        token: String,
        base: String,
        serverIp: String?,
        clientId: String,
        deviceId: String,
        adId: String,
        action: AdAction,
        watchedTimeMs: Int? = nil,
        pausedTimeMs: Int? = nil
    ) async {
        let effectiveBase = serverIp.map { "https://\($0)" } ?? base
        guard let url = URL(string: "\(effectiveBase)/v2/session/\(sessionId)") else { return }
        var adUpdate: [String: Any] = [
            "adId": adId,
            "adAction": action.rawValue,
            "clientTimestamp": Int(Date().timeIntervalSince1970),
        ]
        if let ms = watchedTimeMs { adUpdate["watchedTimeInMs"] = max(0, ms) }
        if let ms = pausedTimeMs  { adUpdate["pausedTimeInMs"]  = max(0, ms) }
        let body: [String: Any] = ["action": 6, "adUpdates": [adUpdate]]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (k, v) in gfnHeaders(token: token, clientId: clientId, deviceId: deviceId, includeOrigin: true) {
            request.setValue(v, forHTTPHeaderField: k)
        }
        request.httpBody = bodyData
        _ = try? await urlSession.data(for: request)
    }

    /// For sessions without usage=2/17 connectionInfo, derive media IP+port from usage=14 entries.
    /// The highest-port usage=14 entry is the media endpoint (e.g. 48322);
    /// the lowest-port entry (e.g. 322) is the RTSPS signaling port.
    /// IP is extracted from the dash-encoded hostname in the rtsps:// resourcePath when the ip
    /// field is absent (e.g. "rtsps://80-84-170-153.cloudmatchbeta.nvidiagrid.net:48322").
    private func extractMediaFromUsage14(
        _ connections: [CloudMatchResponse.SessionPayload.ConnectionInfo]
    ) -> MediaConnectionInfo? {
        let candidates = connections
            .filter { $0.usage == 14 }
            .compactMap { conn -> MediaConnectionInfo? in
                if let ip = conn.ip?.value, conn.port > 0 {
                    guard SessionInfo.isValidHost(ip) else { return nil }
                    return MediaConnectionInfo(ip: ip, port: conn.port)
                }
                guard let path = conn.resourcePath,
                      let host = URL(string: path)?.host,
                      let ip = extractIpFromDashHost(host),
                      conn.port > 0 else { return nil }
                guard SessionInfo.isValidHost(ip) else { return nil }
                return MediaConnectionInfo(ip: ip, port: conn.port)
            }
        return candidates.max(by: { $0.port < $1.port })
    }

    /// Extracts a dotted-decimal IP from a dash-encoded hostname label.
    /// "80-84-170-153.cloudmatchbeta.nvidiagrid.net" → "80.84.170.153"
    private func extractIpFromDashHost(_ host: String) -> String? {
        let label = host.components(separatedBy: ".").first ?? host
        let parts = label.components(separatedBy: "-")
        guard parts.count == 4,
              parts.allSatisfy({ Int($0) != nil && (Int($0)! >= 0) && (Int($0)! <= 255) })
        else { return nil }
        return parts.joined(separator: ".")
    }

    private func defaultIceServers() -> [IceServer] {
        [
            IceServer(urls: ["stun:s1.stun.gamestream.nvidia.com:19308"], username: nil, credential: nil),
            IceServer(urls: ["stun:stun.l.google.com:19302"], username: nil, credential: nil),
        ]
    }
}

// MARK: - Errors

enum CloudMatchError: Error, LocalizedError {
    case sessionCreateFailed(String)
    case missingServerIp

    var errorDescription: String? {
        switch self {
        case .sessionCreateFailed(let msg): return "Session creation failed: \(msg)"
        case .missingServerIp: return "CloudMatch response missing server IP."
        }
    }
}
