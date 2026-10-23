import XCTest
@testable import SteamProtocolCore

final class RecentGamesTests: XCTestCase {
    private let valid = Data("""
    {"version":1,"generatedAt":1,"hostID":"16967682542336782063","hostName":"bc-250","games":[{"id":"16899013876614430720","title":"OutRun","lastPlayed":1,"isShortcut":true,"hero":"/art/16899013876614430720/hero.png"}]}
    """.utf8)

    func testShortcutIDSurvivesDecodeAndLaunchURL() throws {
        let feed = try SteamRecentGamesFeed.decode(valid)
        let url = try XCTUnwrap(feed.games.first?.launchURL(hostID: feed.hostID))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "app" }?.value, "16899013876614430720")
        XCTAssertEqual(items.first { $0.name == "host" }?.value, feed.hostID)
    }
    func testLibraryActionPreservesNativeAndShortcutGameIDs() throws {
        let shortcut = try SteamRecentGamesFeed.decode(valid)
        XCTAssertEqual(shortcut.games.first?.libraryURL(hostID: shortcut.hostID)?.host, "library")
        let nativeData = Data(String(decoding: valid, as: UTF8.self)
            .replacingOccurrences(of: "16899013876614430720", with: "1126750")
            .replacingOccurrences(of: "\"isShortcut\":true", with: "\"isShortcut\":false").utf8)
        let native = try SteamRecentGamesFeed.decode(nativeData)
        let url = try XCTUnwrap(native.games.first?.libraryURL(hostID: native.hostID))
        XCTAssertEqual(url.host, "library")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "app" }?.value, "1126750")
    }
    func testInvalidReplacementPreservesCachedFeed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SteamRecentGamesStore(directory: directory)
        try store.save(valid)
        XCTAssertThrowsError(try store.save(Data("truncated".utf8)))
        XCTAssertEqual(store.load()?.games.first?.title, "OutRun")
        let invalid = Data(String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "16899013876614430720", with: "18446744073709551616").utf8)
        XCTAssertThrowsError(try store.save(invalid))
        XCTAssertEqual(store.load()?.games.first?.title, "OutRun")
    }
    func testArtworkCannotEscapeCacheOrUseAnotherGame() {
        let store = SteamRecentGamesStore(directory: URL(fileURLWithPath: "/tmp/cache"))
        XCTAssertNil(store.artworkURL(gameID: "123", path: "/art/123/../../secret"))
        XCTAssertNil(store.artworkURL(gameID: "123", path: "/art/456/hero.png"))
        XCTAssertNotNil(store.artworkURL(gameID: "123", path: "/art/123/hero.png"))
        XCTAssertNotNil(store.artworkURL(gameID: "123", path: "/art/123/hero-logo-123456abcdef.jpg"))
        XCTAssertNil(store.artworkURL(gameID: "123", path: "/art/123/hero-logo-invalid.jpg"))
    }
}
