import Foundation

/// Desktop capture survives game exit. Require both Steam's game-running
/// status and its return to the launcher UI before treating that as an exit.
public struct SteamGameExitMonitor {
    private var title = ""
    private var gamesRunning: Bool?
    private var observedGame = false
    public init() {}
    public mutating func update(title: String? = nil, gamesRunning: Bool? = nil) -> Bool {
        if let title { self.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let gamesRunning { self.gamesRunning = gamesRunning }
        let steamUI = self.title == "Steam Big Picture Mode" || self.title == "Steam"
        if !self.title.isEmpty, !steamUI, self.gamesRunning == true { observedGame = true }
        return observedGame && steamUI && self.gamesRunning == false
    }
}
