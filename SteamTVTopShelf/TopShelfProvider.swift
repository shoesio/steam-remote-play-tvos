import Foundation
import TVServices

final class TopShelfProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let feed = await SteamRecentLibrary.shared.refresh()
        let store = SteamRecentLibrary.store
        let fallback = Bundle.main.url(forResource: "SteamHero", withExtension: "png")
        var items: [TVTopShelfCarouselItem] = []
        if let feed {
            for game in feed.games {
                guard let link = game.launchURL(hostID: feed.hostID) else { continue }
                let item = TVTopShelfCarouselItem(identifier: game.id)
                item.title = game.title
                item.contextTitle = "Recently Played · Steam Remote Play"
                item.summary = game.summary
                item.genre = game.genre
                var attributes: [TVTopShelfNamedAttribute] = []
                for (name, value) in [("Developer", game.developer), ("Publisher", game.publisher), ("Released", game.releaseDate)] {
                    if let value, !value.isEmpty { attributes.append(TVTopShelfNamedAttribute(name: name, values: [value])) }
                }
                item.namedAttributes = attributes
                let artwork = game.hero.flatMap { store?.artworkURL(gameID: game.id, path: $0) }
                let image = artwork.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? fallback
                if let image { item.setImageURL(image, for: .screenScale1x); item.setImageURL(image, for: .screenScale2x) }
                item.displayAction = TVTopShelfAction(url: game.libraryURL(hostID: feed.hostID) ?? URL(string: "steamtv://launch")!)
                item.playAction = TVTopShelfAction(url: link)
                items.append(item)
            }
        }
        if items.isEmpty, let fallback, let link = URL(string: "steamtv://launch") {
            let item = TVTopShelfCarouselItem(identifier: "steam")
            item.title = "Open SteamOS"; item.contextTitle = "Steam Remote Play"
            item.summary = "Open your Steam library. Recently played games appear here when the PC is available."
            item.setImageURL(fallback, for: .screenScale1x); item.setImageURL(fallback, for: .screenScale2x)
            item.displayAction = TVTopShelfAction(url: link); item.playAction = TVTopShelfAction(url: link)
            items.append(item)
        }
        return TVTopShelfCarouselContent(style: .details, items: items)
    }
}
