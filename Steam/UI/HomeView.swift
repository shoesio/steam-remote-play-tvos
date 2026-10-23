import SwiftUI
import OSLog

struct HomeView: View {
    let onPlay: (GameInfo) -> Void
    let onResume: (ResumableSession) -> Void

    @Environment(GamesViewModel.self) var viewModel
    @Environment(AuthManager.self) var authManager
    @State private var tick = 0

    private static let perfLogger = Logger(subsystem: "CloudNow", category: "HomePerf")

    var body: some View {
        let home = viewModel.homeSnapshot
        let _ = Self.logBodyRender(
            isLoading: viewModel.isLoading,
            hasHomeContent: home.hasHomeContent,
            hasVisibleHomeContent: hasVisibleHomeContent(home),
            heroCount: home.heroGames.count,
            localCount: home.localSunshineGames.count,
            favoriteCount: home.favoriteGames.count,
            libraryCount: home.homeLibraryGames.count,
            popularCount: home.popularGames.count
        )

        ZStack {
            Color.appBackground.ignoresSafeArea()

            if viewModel.isLoading && !home.hasHomeContent {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Color.gray.opacity(0.2)
                            .frame(maxWidth: .infinity)
                            .frame(height: 620)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .shimmer()
                            .padding(.horizontal, 60)
                            .padding(.top, 64)
                        VStack(alignment: .leading, spacing: 48) {
                            skeletonRow
                            skeletonRow
                        }
                        .padding(.top, 48)
                        .padding(.bottom, 60)
                    }
                }
            } else if !hasVisibleHomeContent(home) {
                emptyState
            } else {
                GeometryReader { proxy in
                    ScrollView {
                        homeContent(availableSize: proxy.size, snapshot: home)
                    }
                }
            }
        }
        .onAppear {
            Self.perfLogger.info("HomeView appear heroCount=\(home.heroGames.count) visible=\(hasVisibleHomeContent(home))")
            Task { await viewModel.refreshActiveSessions(authManager: authManager) }
        }
        .onDisappear {
            Self.perfLogger.info("HomeView disappear")
        }
        .task(id: viewModel.resumableSession?.session.sessionId) {
            Self.perfLogger.info("HomeView resumable-session ticker task start hasSession=\(viewModel.resumableSession != nil)")
            guard viewModel.resumableSession != nil else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                tick &+= 1
                if viewModel.resumableSession?.isExpired == true {
                    viewModel.resumableSession = nil
                    return
                }
            }
        }
    }

    private func homeContent(
        availableSize: CGSize,
        snapshot: HomeSnapshot
    ) -> some View {
        let heroGames = snapshot.heroGames
        let _ = Self.logHomeContentRender(availableSize: availableSize, heroCount: heroGames.count)

        return LazyVStack(alignment: .leading, spacing: 48) {
            if !heroGames.isEmpty {
                HeroCarousel(
                    games: heroGames,
                    availableWidth: availableSize.width,
                    availableHeight: availableSize.height,
                    metadata: { viewModel.displayMetadata(for: $0) }
                ) { game in
                    viewModel.isSessionActive(for: game)
                } onPlay: { game in
                    playOrResume(game)
                }
            }
            shelfRows(snapshot)
        }
        .padding(.top, 0)
        .padding(.bottom, 60)
    }

    @ViewBuilder
    private func shelfRows(_ snapshot: HomeSnapshot) -> some View {
        if !snapshot.favoriteGames.isEmpty {
            gameRow(title: "Favorites", games: snapshot.favoriteGames, isFavoritesRow: true)
        }
        if !snapshot.recentlyPlayedGames.isEmpty {
            gameRow(title: "Recently Played", games: snapshot.recentlyPlayedGames)
        }
        if showsGFNContent {
            if !snapshot.homeLibraryGames.isEmpty {
                gameRow(title: "Ready to Launch", games: Array(snapshot.homeLibraryGames.prefix(20)), source: .geforceNow)
            }
        }
        if !snapshot.xcloudNewGames.isEmpty {
            gameRow(title: "New on xCloud", games: Array(snapshot.xcloudNewGames.prefix(20)), source: .xcloud)
        }
        if !snapshot.xcloudPopularGames.isEmpty {
            gameRow(title: "Most Popular", games: Array(snapshot.xcloudPopularGames.prefix(24)), source: .xcloud)
        }
        if !snapshot.xcloudGames.isEmpty {
            gameRow(title: "Xbox Cloud Gaming", games: Array(snapshot.xcloudGames.prefix(20)), source: .xcloud)
        }
        if !snapshot.localSunshineGames.isEmpty {
            gameRow(title: "Sunshine", games: Array(snapshot.localSunshineGames.prefix(20)), source: .sunshine)
        }
        if showsGFNContent {
            if !snapshot.xboxGames.isEmpty {
                gameRow(title: "Xbox & PC Game Pass", games: Array(snapshot.xboxGames.prefix(20)), source: .geforceNow)
            }
            if !snapshot.popularGames.isEmpty {
                gameRow(title: "Popular on GeForce NOW", games: Array(snapshot.popularGames.prefix(24)), source: .geforceNow)
            }
        }
    }

    private var showsGFNContent: Bool {
        authManager.isAuthenticated
    }

    private func hasVisibleHomeContent(_ snapshot: HomeSnapshot) -> Bool {
        return !snapshot.continuePlaying.isEmpty
            || !snapshot.recentlyPlayedGames.isEmpty
            || !snapshot.favoriteGames.isEmpty
            || !snapshot.homeLibraryGames.isEmpty
            || !snapshot.xcloudGames.isEmpty
            || !snapshot.xcloudNewGames.isEmpty
            || !snapshot.xcloudPopularGames.isEmpty
            || !snapshot.localSunshineGames.isEmpty
            || !snapshot.xboxGames.isEmpty
            || !snapshot.popularGames.isEmpty
            || activeResumable != nil
    }

    private var activeResumable: ResumableSession? {
        guard let rs = viewModel.resumableSession, !rs.isExpired else { return nil }
        return rs
    }

    private func gameRow(
        title: String,
        games: [GameInfo],
        source explicitSource: HomeRowSource? = nil,
        isFavoritesRow: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 10) {
                Text(title.uppercased())
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.primary)
                if let source = explicitSource ?? rowSource(for: games) {
                    HomeRowSourceBadge(source: source)
                }
            }
            .padding(.horizontal, 60)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(games) { game in
                        if isFavoritesRow {
                            GameCardView(game: viewModel.gameWithPreferredStore(game), isActive: viewModel.isSessionActive(for: game)) {
                                playOrResume(game)
                            }
                            .frame(width: 200)
                        } else {
                            GameCardView(game: viewModel.gameWithPreferredStore(game), isActive: viewModel.isSessionActive(for: game)) {
                                playOrResume(game)
                            }
                            .frame(width: 200)
                        }
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 24)
            }
            .focusSection()
            .scrollClipDisabled()
        }
    }

    private func rowSource(for games: [GameInfo]) -> HomeRowSource? {
        let sources = games.reduce(into: Set<HomeRowSource>()) { result, game in
            result.formUnion(HomeRowSource.sources(for: game))
        }
        return sources.count == 1 ? sources.first : nil
    }

    private func recentlyPlayedRowGames() -> [GameInfo] {
        var result: [GameInfo] = []
        var seen = Set<String>()

        let activeLocalGame = activeResumable.map { [$0.game] } ?? []
        for game in activeLocalGame + viewModel.continuePlaying + viewModel.recentlyPlayedGames {
            if seen.insert(game.id).inserted {
                result.append(game)
            }
        }
        return result
    }

    private func playOrResume(_ game: GameInfo) {
        if let rs = activeResumable, rs.game.id == game.id {
            onResume(rs)
        } else {
            onPlay(viewModel.gameWithPreferredStore(game))
        }
    }

    private static func logBodyRender(
        isLoading: Bool,
        hasHomeContent: Bool,
        hasVisibleHomeContent: Bool,
        heroCount: Int,
        localCount: Int,
        favoriteCount: Int,
        libraryCount: Int,
        popularCount: Int
    ) {
        perfLogger.debug("HomeView body loading=\(isLoading) hasHomeContent=\(hasHomeContent) visible=\(hasVisibleHomeContent) heroCount=\(heroCount) local=\(localCount) favorites=\(favoriteCount) library=\(libraryCount) popular=\(popularCount)")
    }

    private static func logHomeContentRender(availableSize: CGSize, heroCount: Int) {
        perfLogger.debug("HomeView content render width=\(availableSize.width) height=\(availableSize.height) heroCount=\(heroCount)")
    }

    // MARK: Skeleton Row

    private var skeletonRow: some View {
        VStack(alignment: .leading, spacing: 20) {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.gray.opacity(0.25))
                .frame(width: 180, height: 24)
                .shimmer()
                .padding(.horizontal, 60)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 24) {
                    ForEach(0..<6, id: \.self) { _ in
                        GameCardSkeleton().frame(width: 200)
                    }
                }
                .padding(.horizontal, 60)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text("Nothing here yet")
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Start playing a game to see it here, or add favorites from Games.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 500)
        }
    }
}

private enum HomeRowSource: Hashable {
    case geforceNow
    case sunshine
    case xcloud

    var label: String {
        switch self {
        case .geforceNow:
            return "GFN"
        case .sunshine:
            return "Sunshine"
        case .xcloud:
            return "Xbox"
        }
    }

    var systemImage: String {
        switch self {
        case .geforceNow:
            return "bolt.fill"
        case .sunshine:
            return "sun.max.fill"
        case .xcloud:
            return "xbox.logo"
        }
    }

    var assetImageName: String? {
        switch self {
        case .sunshine:
            return "SunshineLogo"
        case .geforceNow, .xcloud:
            return nil
        }
    }

    static func sources(for game: GameInfo) -> Set<HomeRowSource> {
        var sources = Set<HomeRowSource>()
        if game.isXCloudGame {
            sources.insert(.xcloud)
        }
        if game.isSunshineGame {
            sources.insert(.sunshine)
        }
        if game.variants.contains(where: { $0.appStore != "XCLOUD" && $0.appStore != "SUNSHINE" }) {
            sources.insert(.geforceNow)
        }
        return sources
    }
}

private struct HomeRowSourceBadge: View {
    let source: HomeRowSource

    @Environment(\.colorScheme) private var colorScheme

    private var accent: Color {
        .white.opacity(colorScheme == .dark ? 0.82 : 0.55)
    }

    var body: some View {
        HStack(spacing: 5) {
            if let assetImageName = source.assetImageName {
                Image(assetImageName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
            } else {
                Image(systemName: source.systemImage)
                    .font(.caption2.weight(.bold))
            }
            Text(source.label)
                .font(.caption.weight(.bold))
        }
        .foregroundStyle(.primary)
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(accent.opacity(0.20)))
        )
        .overlay {
            Capsule()
                .strokeBorder(accent, lineWidth: 1)
        }
    }
}

// MARK: - Hero Carousel

private struct HeroCarousel: View {
    let games: [GameInfo]
    let availableWidth: CGFloat
    let availableHeight: CGFloat
    let metadata: (GameInfo) -> CanonicalGame?
    let isActive: (GameInfo) -> Bool
    let onPlay: (GameInfo) -> Void

    @FocusState private var focusedGameID: String?
    @State private var centeredGameID: String?

    private static let perfLogger = Logger(subsystem: "CloudNow", category: "HomePerf")

    private let heroAspectRatio: CGFloat = 16 / 9
    private let maxCardWidth: CGFloat = 1960
    private let maxCardHeight: CGFloat = 900
    private let cardSpacing: CGFloat = 24
    private let topGutter: CGFloat = 0
    private let bottomGutter: CGFloat = 24
    private let horizontalPageInset: CGFloat = 40
    private let verticalViewportInset: CGFloat = 24

    var body: some View {
        let cardWidth = cardWidth(for: availableWidth, availableHeight: availableHeight)
        let cardHeight = cardWidth / heroAspectRatio
        let horizontalInset = horizontalInset(for: availableWidth, cardWidth: cardWidth)
        let heroImageWidth = heroImageWidth(for: cardWidth)
        let _ = Self.logBodyRender(
            availableWidth: availableWidth,
            availableHeight: availableHeight,
            cardWidth: cardWidth,
            cardHeight: cardHeight,
            heroImageWidth: heroImageWidth,
            gameCount: games.count
        )

        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(games) { game in
                    HeroCarouselCard(
                        game: game,
                        isActive: isActive(game),
                        width: cardWidth,
                        height: cardHeight,
                        imageWidth: heroImageWidth,
                        metadata: metadata(game)
                    ) {
                        onPlay(game)
                    }
                    .focused($focusedGameID, equals: game.id)
                    .gameContextMenu(for: game)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, horizontalInset)
            .padding(.top, topGutter)
            .padding(.bottom, bottomGutter)
        }
        .scrollPosition(id: $centeredGameID, anchor: .center)
        .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne, anchor: .center))
        .onChange(of: focusedGameID) { _, gameID in
            guard let gameID, centeredGameID != gameID else { return }
            withAnimation(.smooth(duration: 0.28)) {
                centeredGameID = gameID
            }
        }
        .focusSection()
        .scrollClipDisabled()
        .frame(height: cardHeight + topGutter + bottomGutter)
        .task(id: "\(prefetchKey)|\(heroImageWidth)") {
            Self.perfLogger.info("HeroCarousel prefetch start heroImageWidth=\(heroImageWidth) gameCount=\(games.count) prefetchCount=\(min(3, games.count)) key=\(prefetchKey, privacy: .public)")
            RemoteImagePrefetcher.prefetch(
                games.prefix(3).map { FeaturedTileArtwork.prefetchURL(for: $0, imageWidth: heroImageWidth) }
            )
        }
    }

    private func cardWidth(for availableWidth: CGFloat, availableHeight: CGFloat) -> CGFloat {
        let widthLimit = min(maxCardWidth, max(0, availableWidth - (horizontalPageInset * 2)))
        let heightLimit = min(
            maxCardHeight,
            max(560, availableHeight - topGutter - bottomGutter - verticalViewportInset)
        )
        let heightLimitedWidth = heightLimit * heroAspectRatio
        return max(960, min(widthLimit, heightLimitedWidth))
    }

    private func horizontalInset(for availableWidth: CGFloat, cardWidth: CGFloat) -> CGFloat {
        max(horizontalPageInset, (availableWidth - cardWidth) / 2)
    }

    private func heroImageWidth(for cardWidth: CGFloat) -> Int {
        min(1600, max(1280, Int(cardWidth.rounded(.up))))
    }

    private var prefetchKey: String {
        games.prefix(8).map(\.id).joined(separator: "|")
    }

    private static func logBodyRender(
        availableWidth: CGFloat,
        availableHeight: CGFloat,
        cardWidth: CGFloat,
        cardHeight: CGFloat,
        heroImageWidth: Int,
        gameCount: Int
    ) {
        perfLogger.debug("HeroCarousel body availableWidth=\(availableWidth) availableHeight=\(availableHeight) cardWidth=\(cardWidth) cardHeight=\(cardHeight) heroImageWidth=\(heroImageWidth) gameCount=\(gameCount)")
    }

}

private struct HeroCarouselCard: View {
    let game: GameInfo
    let isActive: Bool
    let width: CGFloat
    let height: CGFloat
    let imageWidth: Int
    let metadata: CanonicalGame?
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            FeaturedTileArtwork(game: game, imageWidth: imageWidth)
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.52)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 210)
            }
            .overlay(alignment: .bottomLeading) {
                metadataOverlay
                    .padding(.horizontal, 38)
                    .padding(.bottom, 30)
            }
            .overlay(alignment: .bottomTrailing) {
                providerLogoBadge
                    .padding(.trailing, 38)
                    .padding(.bottom, 30)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(HeroCarouselButtonStyle())
    }

    private var metadataOverlay: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(titleText)
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.74)
                .multilineTextAlignment(.leading)
                .shadow(color: .black.opacity(0.55), radius: 8, y: 3)
                .frame(maxWidth: 760, alignment: .leading)

            if let metadataText {
                Text(metadataText)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .shadow(color: .black.opacity(0.6), radius: 6, y: 2)
                    .frame(maxWidth: 940, alignment: .leading)
            }

            HStack(alignment: .center, spacing: 12) {
                actionPill
                if let statusText {
                    GlassBadge(text: statusText, systemImage: statusIcon, tone: statusTone)
                }
            }
        }
    }

    private var actionPill: some View {
        Label(isActive ? "Resume" : "Play", systemImage: isActive ? "arrow.counterclockwise" : "play.fill")
            .font(.body.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(.white.opacity(0.18)))
            )
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.42), lineWidth: 1)
            }
    }

    private var providerLogoBadge: some View {
        Group {
            if let sourceBadge = LaunchSourceBadge(game: game) {
                LaunchSourceIconBadge(source: sourceBadge)
            }
        }
    }

    private var titleText: String {
        let text = game.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Untitled App" : text
    }

    private var metadataText: String? {
        guard let metadata else { return nil }
        var parts: [String] = []
        if let platform = metadata.platform, !platform.isEmpty { parts.append(platform) }
        if let year = metadata.releaseYear { parts.append(String(year)) }
        if let developer = metadata.developer, !developer.isEmpty { parts.append(developer) }
        if let publisher = metadata.publisher,
           !publisher.isEmpty,
           publisher != metadata.developer {
            parts.append(publisher)
        }
        if let genre = metadata.genres.first, !genre.isEmpty { parts.append(genre) }
        return parts.isEmpty ? nil : parts.prefix(5).joined(separator: " · ")
    }

    private var statusText: String? {
        if isActive {
            return "Active"
        }
        if game.isInLibrary {
            return nil
        }
        return "Available"
    }

    private var statusIcon: String {
        if isActive {
            return "dot.radiowaves.left.and.right"
        }
        if game.isInLibrary {
            return "checkmark.circle.fill"
        }
        return "play.circle.fill"
    }

    private var statusTone: AppActionButtonStyle.Tone {
        isActive ? .primary : .secondary
    }

}

private struct HeroCarouselButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.white.opacity(isFocused ? 0.82 : 0), lineWidth: isFocused ? 5 : 0)
            }
            .shadow(color: .black.opacity(0.26), radius: 18, y: 8)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .scaleEffect(configuration.isPressed ? 0.995 : 1)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

private struct FeaturedTileArtwork: View {
    let game: GameInfo
    var imageWidth: Int

    var body: some View {
        if let homeHeroURL {
            CachedRemoteImage(url: homeHeroURL, showsPreviousImageWhileLoading: true) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                HeroFallbackArtwork(game: game)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        } else if let coverFallbackURL {
            CoverHeroFallbackArtwork(url: coverFallbackURL, title: game.title)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            HeroFallbackArtwork(game: game)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var homeHeroURL: URL? {
        Self.homeHeroURL(for: game, imageWidth: imageWidth)
    }

    private var coverFallbackURL: URL? {
        Self.coverFallbackURL(for: game)
    }

    static func homeHeroURL(for game: GameInfo, imageWidth: Int) -> URL? {
        guard var raw = game.heroBannerUrl, !raw.isEmpty else { return nil }
        guard raw.contains("img.nvidiagrid.net") else { return URL(string: raw) }
        if let range = raw.range(of: ";w=") {
            raw = String(raw[..<range.lowerBound])
        }
        return URL(string: "\(raw);w=\(imageWidth)")
    }

    static func coverFallbackURL(for game: GameInfo) -> URL? {
        guard let raw = game.boxArtUrl, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static func prefetchURL(for game: GameInfo, imageWidth: Int) -> URL? {
        homeHeroURL(for: game, imageWidth: imageWidth) ?? coverFallbackURL(for: game)
    }
}

private struct CoverHeroFallbackArtwork: View {
    let url: URL
    let title: String

    var body: some View {
        ZStack {
            CachedRemoteImage(url: url, showsPreviousImageWhileLoading: true) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .blur(radius: 24)
                    .saturation(0.92)
                    .brightness(-0.20)
                    .scaleEffect(1.08)
            } placeholder: {
                HeroFallbackArtwork(game: fallbackGame)
            }

            LinearGradient(
                colors: [
                    .black.opacity(0.18),
                    .black.opacity(0.44),
                    .black.opacity(0.72)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            CachedRemoteImage(url: url, showsPreviousImageWhileLoading: true) { image in
                image
                    .resizable()
                    .aspectRatio(2/3, contentMode: .fit)
                    .shadow(color: .black.opacity(0.55), radius: 24, y: 12)
            } placeholder: {
                EmptyView()
            }
            .frame(maxWidth: 360, maxHeight: 520)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            .padding(.trailing, 110)
            .opacity(0.82)
        }
    }

    private var fallbackGame: GameInfo {
        GameInfo(
            id: title,
            title: title,
            boxArtUrl: nil,
            heroBannerUrl: nil,
            isInLibrary: false,
            variants: []
        )
    }
}

private struct HeroFallbackArtwork: View {
    let game: GameInfo

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.07, blue: 0.08),
                    Color(red: 0.12, green: 0.16, blue: 0.13),
                    Color(red: 0.03, green: 0.03, blue: 0.04)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Text(game.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.12))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

// MARK: - Hero Artwork Review

struct HeroArtworkReviewView: View {
    let game: GameInfo

    @Environment(GamesViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 440, maximum: 570), spacing: 36)
    ]

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                        if let status = viewModel.heroArtworkScrapeStatus {
                            Text(status)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button {
                        Task {
                            await viewModel.scrapeHeroArtworkCandidates(for: game)
                        }
                    } label: {
                        Label("Rescrape", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .secondary, minWidth: 150))
                    .disabled(viewModel.isScrapingHeroArtwork)

                    Button {
                        dismiss()
                    } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 130))
                }

                if viewModel.isScrapingHeroArtwork {
                    VStack(spacing: 18) {
                        ProgressView()
                            .scaleEffect(1.15)
                        Text("Searching artwork")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.heroArtworkCandidates.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("No artwork options found")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 36) {
                            ForEach(viewModel.heroArtworkCandidates) { candidate in
                                Button {
                                    viewModel.applyHeroArtworkCandidate(candidate, to: game)
                                    dismiss()
                                } label: {
                                    HeroArtworkCandidateTile(candidate: candidate)
                                }
                                .buttonStyle(.card)
                                .frame(height: 316)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 18)
                    }
                    .scrollClipDisabled()
                }
            }
            .padding(54)
        }
        .task(id: game.id) {
            await viewModel.scrapeHeroArtworkCandidates(for: game)
        }
    }
}

private struct CoverArtworkReviewView: View {
    let game: GameInfo

    @Environment(GamesViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.adaptive(minimum: 360, maximum: 460), spacing: 36)
    ]

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(game.title)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                        if let status = viewModel.coverArtworkScrapeStatus {
                            Text(status)
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Button {
                        Task { await viewModel.scrapeCoverArtworkCandidates(for: game) }
                    } label: {
                        Label("Rescrape", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .secondary, minWidth: 150))
                    .disabled(viewModel.isScrapingCoverArtwork)

                    Button { dismiss() } label: {
                        Label("Close", systemImage: "xmark")
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 130))
                }

                if viewModel.isScrapingCoverArtwork {
                    VStack(spacing: 18) {
                        ProgressView().scaleEffect(1.15)
                        Text("Searching covers")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.coverArtworkCandidates.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                            .font(.system(size: 48, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("No cover options found")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 36) {
                            ForEach(viewModel.coverArtworkCandidates) { candidate in
                                Button {
                                    viewModel.applyCoverArtworkCandidate(candidate, to: game)
                                    dismiss()
                                } label: {
                                    HeroArtworkCandidateTile(candidate: candidate)
                                }
                                .buttonStyle(.card)
                                .frame(height: 316)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 18)
                    }
                    .scrollClipDisabled()
                }
            }
            .padding(54)
        }
        .task(id: game.id) {
            await viewModel.scrapeCoverArtworkCandidates(for: game)
        }
    }
}

private struct GameMetadataReviewView: View {
    let game: GameInfo

    @Environment(GamesViewModel.self) private var viewModel
    @Environment(\.dismiss) private var dismiss
    @State private var correctedTitle: String
    @State private var isApplying = false

    init(game: GameInfo) {
        self.game = game
        _correctedTitle = State(initialValue: game.title)
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 28) {
                HStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Fix Name & Metadata")
                            .font(.title2.weight(.semibold))
                        Text("Current name: \(game.title)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close") { dismiss() }
                        .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 130))
                }

                HStack(spacing: 18) {
                    TextField("Correct game name", text: $correctedTitle)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 22)
                        .frame(maxWidth: 760, minHeight: 58)
                        .background(.white.opacity(0.10), in: Capsule())
                        .onSubmit { search() }

                    Button { search() } label: {
                        if viewModel.isSearchingMetadata {
                            ProgressView()
                        } else {
                            Label("Search Metadata", systemImage: "magnifyingglass")
                        }
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 220))
                    .disabled(trimmedTitle.count < 2 || viewModel.isSearchingMetadata || isApplying)

                    Button {
                        apply(metadata: nil)
                    } label: {
                        Label("Use Name Only", systemImage: "textformat")
                    }
                    .buttonStyle(AppActionButtonStyle(tone: .secondary, minWidth: 190))
                    .disabled(trimmedTitle.isEmpty || isApplying)
                }

                if let status = viewModel.metadataSearchStatus {
                    Text(status)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if viewModel.isSearchingMetadata || isApplying {
                    VStack(spacing: 18) {
                        ProgressView().scaleEffect(1.15)
                        Text(isApplying ? "Applying name, metadata, and missing artwork" : "Searching GameDB")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !viewModel.metadataSearchCandidates.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 18) {
                            ForEach(Array(viewModel.metadataSearchCandidates.enumerated()), id: \.offset) { _, metadata in
                                Button {
                                    apply(metadata: metadata)
                                } label: {
                                    metadataMatchRow(metadata)
                                }
                                .buttonStyle(.card)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 18)
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "text.magnifyingglass")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("Enter the correct name, then search and confirm a match.")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding(54)
        }
        .onAppear {
            viewModel.resetMetadataSearch()
        }
    }

    private var trimmedTitle: String {
        correctedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func search() {
        guard trimmedTitle.count >= 2 else { return }
        Task { await viewModel.searchMetadata(correctedTitle: trimmedTitle) }
    }

    private func apply(metadata: GameMetadataLookupResult?) {
        guard !trimmedTitle.isEmpty else { return }
        isApplying = true
        Task {
            await viewModel.applyCorrectedName(trimmedTitle, metadata: metadata, to: game)
            dismiss()
        }
    }

    private func metadataMatchRow(_ metadata: GameMetadataLookupResult) -> some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(metadata.title ?? trimmedTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(metadataDetails(metadata))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let summary = metadata.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            Label("Use This Match", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.primary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataDetails(_ metadata: GameMetadataLookupResult) -> String {
        var parts: [String] = []
        if let platform = metadata.platform, !platform.isEmpty { parts.append(platform) }
        if let year = metadata.releaseYear { parts.append(String(year)) }
        if let developer = metadata.developer, !developer.isEmpty { parts.append("Developer: \(developer)") }
        if let publisher = metadata.publisher, !publisher.isEmpty { parts.append("Publisher: \(publisher)") }
        if !metadata.genres.isEmpty { parts.append(metadata.genres.prefix(3).joined(separator: ", ")) }
        return parts.isEmpty ? "GameDB metadata match" : parts.joined(separator: " · ")
    }
}

private struct HeroArtworkCandidateTile: View {
    let candidate: GameMetadataArtworkCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HeroArtworkCandidatePreview(candidate: candidate)
                .frame(height: 220)

            VStack(alignment: .leading, spacing: 8) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                HStack(spacing: 8) {
                    ArtworkMetadataBadge(text: sourceLabel, systemImage: sourceIcon)
                    ArtworkMetadataBadge(text: roleLabel, systemImage: "rectangle.on.rectangle")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 96, maxHeight: 96, alignment: .topLeading)
            .background(.white.opacity(0.055))
        }
        .frame(maxWidth: .infinity, minHeight: 316, maxHeight: 316, alignment: .topLeading)
        .background(.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private var displayTitle: String {
        candidate.subtitle.replacingOccurrences(
            of: #"(?i)^SteamGridDB\s*[·•-]\s*"#,
            with: "",
            options: .regularExpression
        )
    }

    private var sourceLabel: String {
        switch candidate.source {
        case .gameDB:
            return "GameDB"
        case .igdb:
            return "IGDB"
        case .steamGridDB:
            return "SteamGridDB"
        case .sunshineSelectedCover:
            return "Sunshine"
        case .geforceNow:
            return "GFN"
        case .providerMetadata:
            return "Provider"
        case .fallback:
            return "Fallback"
        }
    }

    private var sourceIcon: String {
        switch candidate.source {
        case .gameDB, .igdb, .steamGridDB:
            return "sparkles"
        case .sunshineSelectedCover:
            return "sun.max.fill"
        case .geforceNow, .providerMetadata:
            return "bolt.fill"
        case .fallback:
            return "photo"
        }
    }

    private var roleLabel: String {
        switch candidate.role {
        case .heroBackground:
            return "Hero"
        case .screenshot:
            return "Screenshot"
        case .tileCover:
            return "Cover"
        case .fallbackBlurredCover:
            return "Fallback"
        }
    }
}

private struct ArtworkMetadataBadge: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.white.opacity(0.07), in: Capsule())
            .overlay { Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 1) }
    }
}

private struct GameContextMenuModifier: ViewModifier {
    let game: GameInfo

    @Environment(GamesViewModel.self) private var viewModel
    @Environment(AuthManager.self) private var authManager
    @State private var artworkReviewGame: GameInfo?
    @State private var coverArtworkReviewGame: GameInfo?
    @State private var metadataReviewGame: GameInfo?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                if viewModel.isSessionActive(for: game) {
                    Button(role: .destructive) {
                        Task {
                            await viewModel.stopStream(for: game, authManager: authManager)
                        }
                    } label: {
                        Label("Stop Stream", systemImage: "stop.circle")
                    }
                }

                Button {
                    viewModel.toggleFavorite(game.id)
                } label: {
                    let isFavorite = viewModel.isFavorite(game.id)
                    Label(
                        isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: isFavorite ? "star.slash.fill" : "star"
                    )
                }

                Button {
                    if viewModel.isInHeroes(game) {
                        viewModel.hideFromHeroes(game)
                    } else {
                        viewModel.showInHeroes(game)
                    }
                } label: {
                    let isHero = viewModel.isInHeroes(game)
                    Label(
                        isHero ? "Remove from Heroes" : "Add to Heroes",
                        systemImage: isHero ? "eye.slash" : "rectangle.stack.badge.plus"
                    )
                }

                Menu("Change Artwork", systemImage: "photo.stack") {
                    Button {
                        coverArtworkReviewGame = game
                    } label: {
                        Label("Change Cover Artwork", systemImage: "rectangle.portrait")
                    }
                    Button {
                        artworkReviewGame = game
                    } label: {
                        Label("Change Hero Artwork", systemImage: "photo.on.rectangle.angled")
                    }
                }

                Button {
                    metadataReviewGame = game
                } label: {
                    Label("Fix Name & Metadata", systemImage: "text.magnifyingglass")
                }

                if game.variants.count > 1 {
                    Menu("Launch via...") {
                        ForEach(game.variants, id: \.id) { variant in
                            Button {
                                viewModel.setPreferredStore(gameId: game.id, variantId: variant.id)
                            } label: {
                                if viewModel.preferredVariantId(for: game) == variant.id {
                                    Label(variant.storeName, systemImage: "checkmark")
                                } else {
                                    Text(variant.storeName)
                                }
                            }
                        }
                    }
                }
            }
            .sheet(item: $artworkReviewGame) { selectedGame in
                HeroArtworkReviewView(game: selectedGame)
                    .environment(viewModel)
            }
            .sheet(item: $coverArtworkReviewGame) { selectedGame in
                CoverArtworkReviewView(game: selectedGame)
                    .environment(viewModel)
            }
            .sheet(item: $metadataReviewGame) { selectedGame in
                GameMetadataReviewView(game: selectedGame)
                    .environment(viewModel)
            }
    }
}

extension View {
    func gameContextMenu(for game: GameInfo) -> some View {
        modifier(GameContextMenuModifier(game: game))
    }
}

private struct HeroArtworkCandidatePreview: View {
    let candidate: GameMetadataArtworkCandidate

    var body: some View {
        ZStack {
            Color.white.opacity(0.07)

            if candidate.role == .tileCover || candidate.role == .fallbackBlurredCover {
                coverPreview
            } else {
                landscapePreview
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .clipped()
    }

    private var landscapePreview: some View {
        GeometryReader { proxy in
            CachedRemoteImage(url: URL(string: candidate.url), showsPreviousImageWhileLoading: true) { image in
                image
                    .resizable()
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            } placeholder: {
                placeholder
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var coverPreview: some View {
        GeometryReader { proxy in
            ZStack {
                CachedRemoteImage(url: URL(string: candidate.url), showsPreviousImageWhileLoading: true) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .blur(radius: 18)
                        .saturation(0.9)
                        .brightness(-0.22)
                        .scaleEffect(1.08)
                        .clipped()
                } placeholder: {
                    placeholder
                }

                CachedRemoteImage(url: URL(string: candidate.url), showsPreviousImageWhileLoading: true) { image in
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: proxy.size.width - 80, maxHeight: proxy.size.height - 30)
                        .shadow(color: .black.opacity(0.45), radius: 16, y: 8)
                } placeholder: {
                    EmptyView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(.white.opacity(0.08))
            .overlay {
                Image(systemName: "photo")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
    }
}
