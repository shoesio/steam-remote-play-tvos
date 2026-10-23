import XCTest
@testable import SteamProtocolCore

final class SessionOwnershipTests: XCTestCase {
    func testNewLauncherRevokesOldLaunchersIncludingOnReopening() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let main = SteamSessionOwnership(container: container, appID: "main")
        let child = SteamSessionOwnership(container: container, appID: "child")
        XCTAssertFalse(main.isOwner)
        try main.claim(); XCTAssertTrue(main.isOwner); XCTAssertFalse(child.isOwner)
        try child.claim(); XCTAssertTrue(child.isOwner); XCTAssertFalse(main.isOwner)
        try main.claim(); XCTAssertTrue(main.isOwner); XCTAssertFalse(child.isOwner)
        let replacement = SteamSessionOwnership(container: container, appID: "main")
        XCTAssertFalse(replacement.isOwner)
        try replacement.claim(); XCTAssertTrue(replacement.isOwner); XCTAssertFalse(main.isOwner)
    }
    func testGameHandoverWaitsForPreviousGameToEnd() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let a = SteamSessionOwnership(container: container, appID: "A")
        let b = SteamSessionOwnership(container: container, appID: "B")
        try a.prepareGameLaunch(hostID: 1, gameID: 100, gamesRunning: false, exitShortcut: "controllerStartSelect", now: 1000)
        XCTAssertThrowsError(try b.prepareGameLaunch(hostID: 1, gameID: 200, gamesRunning: true, now: 1001))
        XCTAssertThrowsError(try b.prepareGameLaunch(hostID: 1, gameID: 200, gamesRunning: false, now: 1001))
        try a.prepareGameLaunch(hostID: 1, gameID: 100, gamesRunning: true, exitShortcut: "controllerStartSelect", now: 1002) // Rejoin.
        XCTAssertEqual(b.recordedExitShortcut(hostID: 1), "controllerStartSelect")
        XCTAssertEqual(b.recordedGame(hostID: 1), 100)
        XCTAssertNil(b.recordedGame(hostID: 2))
        b.gameEnded(hostID: 1, gameID: 200) // Cannot release another game's record.
        XCTAssertThrowsError(try b.prepareGameLaunch(hostID: 1, gameID: 200, gamesRunning: true, now: 1003))
        a.gameEnded(hostID: 1, gameID: 100)
        XCTAssertNil(b.recordedGame(hostID: 1))
        try b.prepareGameLaunch(hostID: 1, gameID: 200, gamesRunning: false, now: 1004)
    }
    func testUnknownRunningGameIsBlockedAndOldStoppedRecordExpires() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let owner = SteamSessionOwnership(container: container, appID: "A")
        XCTAssertThrowsError(try owner.prepareGameLaunch(hostID: 1, gameID: 100, gamesRunning: true, now: 1000))
        try owner.prepareGameLaunch(hostID: 1, gameID: 100, gamesRunning: false, now: 1000)
        try owner.prepareGameLaunch(hostID: 1, gameID: 200, gamesRunning: false, now: 1031)
        try owner.prepareGameLaunch(hostID: 2, gameID: 300, gamesRunning: false, now: 1032)
    }
    func testMissingSharedContainerFailsClosed() {
        let owner = SteamSessionOwnership(container: nil, appID: "main")
        XCTAssertThrowsError(try owner.claim()); XCTAssertFalse(owner.isOwner)
    }
}
