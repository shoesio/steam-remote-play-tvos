import Foundation

/// One foreground launcher owns this Apple TV's paired Steam identity.
/// Atomic file reads avoid cross-process UserDefaults cache delays.
public final class SteamSessionOwnership {
    private let token = UUID().uuidString
    private let file: URL?
    private let gameFile: URL?
    private let appID: String
    public init(container: URL?, appID: String) {
        file = container?.appendingPathComponent("Library/Caches/SteamTV-session-owner.json")
        gameFile = container?.appendingPathComponent("Library/Caches/SteamTV-running-game.json")
        self.appID = appID
    }
    public func claim() throws {
        guard let file else { throw OwnershipError.containerUnavailable }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let record = ["token": token, "app": appID]
        try JSONSerialization.data(withJSONObject: record).write(to: file, options: .atomic)
    }
    public func recordedGame(hostID: UInt64) -> UInt64? {
        guard let gameFile, let data = try? Data(contentsOf: gameFile),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              record["host"] == String(hostID) else { return nil }
        return record["game"].flatMap(UInt64.init)
    }
    public func recordedExitShortcut(hostID: UInt64) -> String? {
        guard let gameFile, let data = try? Data(contentsOf: gameFile),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              record["host"] == String(hostID) else { return nil }
        return record["exitShortcut"]
    }
    public func prepareGameLaunch(hostID: UInt64, gameID: UInt64, gamesRunning: Bool?, exitShortcut: String? = nil, now: TimeInterval = Date().timeIntervalSince1970) throws {
        guard let gameFile else { throw OwnershipError.containerUnavailable }
        let record = (try? Data(contentsOf: gameFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
        let sameHost = record?["host"] == String(hostID)
        let sameGame = sameHost && record?["game"] == String(gameID)
        let recentLaunch = sameHost && now - (record?["started"].flatMap(Double.init) ?? 0) < 30
        if !sameGame && (gamesRunning == true || recentLaunch) { throw OwnershipError.anotherGameRunning }
        try FileManager.default.createDirectory(at: gameFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        var next = ["host": String(hostID), "game": String(gameID), "started": String(now)]
        if let exitShortcut { next["exitShortcut"] = exitShortcut }
        try JSONSerialization.data(withJSONObject: next).write(to: gameFile, options: .atomic)
    }
    public func gameEnded(hostID: UInt64, gameID: UInt64) {
        guard let gameFile, let data = try? Data(contentsOf: gameFile),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              record["host"] == String(hostID), record["game"] == String(gameID) else { return }
        try? Data("{}".utf8).write(to: gameFile, options: .atomic)
    }
    public var isOwner: Bool {
        guard let file, let data = try? Data(contentsOf: file),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String:String] else { return false }
        return record["token"] == token
    }
    enum OwnershipError: LocalizedError {
        case containerUnavailable, anotherGameRunning
        var errorDescription: String? {
            switch self {
            case .containerUnavailable: return "Shared Steam settings are unavailable. Reinstall this app."
            case .anotherGameRunning: return "Another game is still running. Close it through Steam before launching this game."
            }
        }
    }
}
