import XCTest
@testable import SteamProtocolCore

final class GameExitMonitorTests: XCTestCase {
    func testCloseGameRequiresBothHostStatusAndReturnToSteam() {
        var monitor = SteamGameExitMonitor()
        XCTAssertFalse(monitor.update(gamesRunning: true))
        XCTAssertFalse(monitor.update(title: "Eden | Mario Kart"))
        XCTAssertFalse(monitor.update(title: "Steam Big Picture Mode")) // Overlay while game runs.
        XCTAssertTrue(monitor.update(gamesRunning: false))
    }
    func testStatusMayArriveBeforeTitleAndMissingStatusDoesNotMeanExit() {
        var monitor = SteamGameExitMonitor()
        XCTAssertFalse(monitor.update(title: "Eden", gamesRunning: true))
        XCTAssertFalse(monitor.update(gamesRunning: false))
        XCTAssertTrue(monitor.update(title: "Steam"))
        var unknown = SteamGameExitMonitor()
        XCTAssertFalse(unknown.update(title: "Eden"))
        XCTAssertFalse(unknown.update(title: "Steam"))
    }
    func testStartupInSteamDoesNotExitBeforeGameObserved() {
        var monitor = SteamGameExitMonitor()
        XCTAssertFalse(monitor.update(title: "Steam Big Picture Mode", gamesRunning: false))
        XCTAssertFalse(monitor.update(title: "Eden"))
        XCTAssertFalse(monitor.update(title: "Steam"))
    }
}
