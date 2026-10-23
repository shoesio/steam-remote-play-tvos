import CryptoKit
import SwiftUI
import UIKit

private final class RemoteImageMemoryCache {
    static let shared = RemoteImageMemoryCache()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 180 * 1024 * 1024
    }

    func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func insert(_ image: UIImage, for url: URL, cost: Int) {
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }
}

struct CachedRemoteImage<Content: View, Placeholder: View>: View {
    let url: URL?
    var showsPreviousImageWhileLoading: Bool
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var uiImage: UIImage?
    @State private var loadedURL: URL?

    init(
        url: URL?,
        showsPreviousImageWhileLoading: Bool = false,
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.showsPreviousImageWhileLoading = showsPreviousImageWhileLoading
        self.content = content
        self.placeholder = placeholder
        let cachedImage = url.flatMap { RemoteImageMemoryCache.shared.image(for: $0) }
        _uiImage = State(initialValue: cachedImage)
        _loadedURL = State(initialValue: cachedImage == nil ? nil : url)
    }

    var body: some View {
        Group {
            if let uiImage, loadedURL == url || showsPreviousImageWhileLoading {
                content(Image(uiImage: uiImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            await load()
        }
    }

    private func load() async {
        guard let url else {
            uiImage = nil
            loadedURL = nil
            return
        }

        if let cached = RemoteImageMemoryCache.shared.image(for: url) {
            uiImage = cached
            loadedURL = url
            return
        }

        if !showsPreviousImageWhileLoading {
            uiImage = nil
            loadedURL = nil
        }

        if let image = await RemoteImageLoader.load(url) {
            guard self.url == url else { return }
            uiImage = image
            loadedURL = url
        } else if !showsPreviousImageWhileLoading {
            uiImage = nil
            loadedURL = nil
        }
    }
}

enum RemoteImagePrefetcher {
    static func prefetch(_ urls: [URL?]) {
        let uniqueURLs = Array(Set(urls.compactMap(\.self)))
        for url in uniqueURLs where RemoteImageMemoryCache.shared.image(for: url) == nil {
            Task.detached(priority: .utility) {
                _ = await RemoteImageLoader.load(url)
            }
        }
    }
}

private actor RemoteImageRequestCoordinator {
    static let shared = RemoteImageRequestCoordinator()

    private var tasks: [URL: Task<UIImage?, Never>] = [:]

    func image(for url: URL) async -> UIImage? {
        if let task = tasks[url] {
            return await task.value
        }

        let task = Task<UIImage?, Never> {
            await RemoteImageLoader.loadUncoordinated(url)
        }
        tasks[url] = task
        let image = await task.value
        tasks[url] = nil
        return image
    }
}

private enum RemoteImageLoader {
    static func load(_ url: URL) async -> UIImage? {
        await RemoteImageRequestCoordinator.shared.image(for: url)
    }

    fileprivate static func loadUncoordinated(_ url: URL) async -> UIImage? {
        if let cached = RemoteImageMemoryCache.shared.image(for: url) {
            return cached
        }

        if url.isFileURL {
            do {
                let artworkURL = persistentSunshineArtworkURL(for: url)
                let data = try Data(contentsOf: artworkURL)
                guard let image = UIImage(data: data) else { return nil }
                RemoteImageMemoryCache.shared.insert(image, for: url, cost: data.count)
                return image
            } catch {
                return nil
            }
        }

        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 30)
        for cacheURL in diskCacheURLs(for: url) {
            if let diskData = try? Data(contentsOf: cacheURL),
               let image = UIImage(data: diskData) {
                if cacheURL != diskCacheURL(for: url) {
                    persist(diskData, for: url)
                }
                RemoteImageMemoryCache.shared.insert(image, for: url, cost: diskData.count)
                return image
            }
        }

        if let cachedResponse = URLCache.shared.cachedResponse(for: request),
           let image = UIImage(data: cachedResponse.data) {
            persist(cachedResponse.data, for: url)
            RemoteImageMemoryCache.shared.insert(image, for: url, cost: cachedResponse.data.count)
            return image
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let image = UIImage(data: data) else { return nil }
            URLCache.shared.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
            persist(data, for: url)
            RemoteImageMemoryCache.shared.insert(image, for: url, cost: data.count)
            return image
        } catch {
            return nil
        }
    }

    /// Sunshine card artwork is library data, not disposable network cache data.
    /// Older snapshots can still contain a URL in Library/Caches, so migrate that
    /// file on first display and resolve the old URL to its durable location.
    private static func persistentSunshineArtworkURL(for url: URL) -> URL {
        let marker = "/CloudNow/SunshineAssets/"
        guard let markerRange = url.path.range(of: marker) else { return url }

        let relativePath = String(url.path[markerRange.upperBound...])
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let persistentURL = base
            .appendingPathComponent("CloudNow", isDirectory: true)
            .appendingPathComponent("SunshineAssets", isDirectory: true)
            .appendingPathComponent(relativePath, isDirectory: false)

        if FileManager.default.fileExists(atPath: persistentURL.path) {
            return persistentURL
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return url }

        do {
            try FileManager.default.createDirectory(
                at: persistentURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(at: url, to: persistentURL)
            return persistentURL
        } catch {
            return url
        }
    }

    private static func persist(_ data: Data, for url: URL) {
        do {
            let directory = try writableDiskCacheDirectory()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: diskCacheURL(for: url, directory: directory), options: [.atomic])
        } catch {
            // URLCache and memory cache are still usable if the app-owned cache cannot write.
        }
    }

    private static func diskCacheURL(for url: URL) -> URL {
        diskCacheURL(for: url, directory: diskCacheDirectory)
    }

    private static func diskCacheURL(for url: URL, directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        return directory.appendingPathComponent("\(name).\(ext)")
    }

    private static func diskCacheURLs(for url: URL) -> [URL] {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        let ext = url.pathExtension.isEmpty ? "img" : url.pathExtension
        let urls = diskCacheDirectories.map {
            $0.appendingPathComponent("\(name).\(ext)")
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    private static var diskCacheDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("CloudNow", isDirectory: true)
            .appendingPathComponent("RemoteImages", isDirectory: true)
    }

    private static var legacyDiskCacheDirectory: URL {
        diskCacheDirectories.first {
            $0.path.contains("/Caches/")
        } ?? diskCacheDirectory
    }

    private static var diskCacheDirectories: [URL] {
        let bases = [
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
            FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
            FileManager.default.temporaryDirectory
        ].compactMap { $0 }

        var seen = Set<String>()
        return bases.compactMap { base in
            let url = base
                .appendingPathComponent("CloudNow", isDirectory: true)
                .appendingPathComponent("RemoteImages", isDirectory: true)
            return seen.insert(url.path).inserted ? url : nil
        }
    }

    private static func writableDiskCacheDirectory() throws -> URL {
        var lastError: Error?
        for directory in diskCacheDirectories {
            do {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), !isDirectory.boolValue {
                    try FileManager.default.removeItem(at: directory)
                }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return directory
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CocoaError(.fileWriteNoPermission)
    }
}
