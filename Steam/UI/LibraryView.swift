import SwiftUI

private enum LibrarySortOrder: String, CaseIterable {
    case `default`   = "Default"
    case titleAZ     = "A → Z"
    case titleZA     = "Z → A"
    case recentFirst = "Recently Played"
}

private enum LibraryScope: String, CaseIterable {
    case ready = "Ready to Launch"
    case sunshine = "Sunshine"
    case catalog = "GFN Catalog"
}

private struct LibraryStoreFilter: Identifiable {
    let id: String
    let label: String
    let aliases: Set<String>

    static let majorStores: [LibraryStoreFilter] = [
        .init(id: "XBOX", label: "Xbox", aliases: ["XBOX", "MICROSOFT"]),
        .init(id: "STEAM", label: "Steam", aliases: ["STEAM"]),
        .init(id: "EPIC_GAMES_STORE", label: "Epic", aliases: ["EPIC_GAMES_STORE"]),
        .init(id: "UBISOFT", label: "Ubisoft", aliases: ["UBISOFT"]),
        .init(id: "EA_APP", label: "EA", aliases: ["EA_APP", "ORIGIN"]),
        .init(id: "GOG", label: "GOG", aliases: ["GOG"]),
        .init(id: "BATTLENET", label: "Battle.net", aliases: ["BATTLENET", "BATTLE_NET"]),
    ]
}

struct LibraryView: View {
    let games: [GameInfo]
    let onPlay: (GameInfo) -> Void

    @Environment(GamesViewModel.self) var viewModel

    @State private var scope: LibraryScope = .ready
    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .default
    @State private var selectedStore: String? = nil

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40)
    ]

    private var sourceGames: [GameInfo] {
        switch scope {
        case .ready: return games
        case .sunshine: return viewModel.localSunshineGames
        case .catalog: return viewModel.mainGames
        }
    }

    private var availableStoreFilters: [LibraryStoreFilter] {
        let stores = Set(sourceGames.flatMap { game in
            scope == .ready ? game.ownedStores : game.variants.map(\.appStore)
        }.filter { $0 != "unknown" })
        return LibraryStoreFilter.majorStores.filter { !$0.aliases.isDisjoint(with: stores) }
    }

    private var filteredGames: [GameInfo] {
        var result = sourceGames
        if let selectedStore,
           let filter = LibraryStoreFilter.majorStores.first(where: { $0.id == selectedStore }) {
            result = result.filter { game in
                gameMatchesStoreFilter(game, filter: filter)
            }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        }
        switch sortOrder {
        case .default: break
        case .titleAZ: result.sort { $0.title < $1.title }
        case .titleZA: result.sort { $0.title > $1.title }
        case .recentFirst:
            let order = viewModel.recentlyPlayedIds
            result.sort {
                let li = order.firstIndex(of: $0.id) ?? Int.max
                let ri = order.firstIndex(of: $1.id) ?? Int.max
                return li < ri
            }
        }
        return result
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            if sourceGames.isEmpty && viewModel.isLoading {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 40) {
                        ForEach(0..<12, id: \.self) { _ in
                            GameCardSkeleton()
                        }
                    }
                    .padding(60)
                }
                .allowsHitTesting(false)
            } else if filteredGames.isEmpty {
                emptyState
            } else {
                gameGrid
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $sortOrder) {
                        ForEach(LibrarySortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: "arrow.up.arrow.down")
                }
            }
        }
        .searchable(text: $searchText, prompt: searchPrompt)
        .onChange(of: sourceGames) { _, _ in
            if let selectedStore, !availableStoreFilters.contains(where: { $0.id == selectedStore }) {
                self.selectedStore = nil
            }
        }
        .onChange(of: scope) { _, _ in
            selectedStore = nil
        }
    }

    private var gameGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
            scopePicker
                    .padding(.bottom, availableStoreFilters.count > 1 ? 0 : 24)

                Text(scopeDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 60)
                    .padding(.top, availableStoreFilters.count > 1 ? 20 : 0)

                if availableStoreFilters.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            filterChip("All", isSelected: selectedStore == nil) { selectedStore = nil }
                            ForEach(availableStoreFilters) { store in
                                filterChip(store.label, isSelected: selectedStore == store.id) {
                                    selectedStore = selectedStore == store.id ? nil : store.id
                                }
                            }
                        }
                        .padding(.horizontal, 60)
                    }
                    .scrollClipDisabled()
                    .padding(.vertical, 32)
                }
                LazyVGrid(columns: columns, spacing: 40) {
                    ForEach(filteredGames) { game in
                        Button {
                            onPlay(viewModel.gameWithPreferredStore(game))
                        } label: {
                            GameCardLabel(game: viewModel.gameWithPreferredStore(game))
                        }
                        .aspectRatio(2/3, contentMode: .fit)
                        .buttonStyle(SquareGameCardButtonStyle())
                        .gameContextMenu(for: game)
                    }
                }
                .padding(60)
                .padding(.top, 0)
            }
        }
    }

    private var scopePicker: some View {
        Picker("Games", selection: $scope) {
            ForEach(LibraryScope.allCases, id: \.self) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 620)
        .padding(.horizontal, 60)
        .padding(.top, 36)
    }

    private func filterChip(_ label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(AppActionButtonStyle(tone: isSelected ? .primary : .secondary, minWidth: 96))
    }

    private func gameMatchesStoreFilter(_ game: GameInfo, filter: LibraryStoreFilter) -> Bool {
        if scope == .ready {
            return game.variants.contains { $0.isOwned && filter.aliases.contains($0.appStore) }
        }
        return game.variants.contains { filter.aliases.contains($0.appStore) }
    }

    private var scopeDescription: String {
        switch scope {
        case .ready:
            return "Games NVIDIA reports as added to your GeForce NOW library. These are the best candidates to launch from Apple TV."
        case .sunshine:
            return "Apps available from your paired Sunshine host. Launch them directly on this Apple TV."
        case .catalog:
            return "Games supported by GeForce NOW. Some may require a purchase, store sign-in, subscription, or adding in the official GFN app first."
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            scopePicker
                .padding(.bottom, 8)

            Image(systemName: emptyIcon)
                .font(.system(size: 60))
                .foregroundStyle(.secondary)
            Text(emptyTitle)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
            if let err = emptyError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.8))
                    .multilineTextAlignment(.center)
            } else {
                Text(emptyDescription)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(60)
    }

    private var emptyTitle: String {
        if scope == .sunshine, viewModel.sunshineError != nil {
            return "Sunshine Unavailable"
        }
        if scope == .ready, viewModel.libraryError != nil {
            return "Library Failed to Load"
        }
        if scope == .catalog, !searchText.isEmpty {
            return "No Matches"
        }
        switch scope {
        case .ready:
            return "No Ready Games"
        case .sunshine:
            return "No Sunshine Apps"
        case .catalog:
            return "No Catalog Games"
        }
    }

    private var emptyDescription: String {
        switch scope {
        case .ready:
            return "Games added to your GeForce NOW library will appear here."
        case .sunshine:
            return "Pair Sunshine and refresh to see local apps from your host."
        case .catalog:
            return "No catalog games matched your search."
        }
    }

    private var emptyError: String? {
        switch scope {
        case .ready:
            return viewModel.libraryError ?? viewModel.error
        case .sunshine:
            return viewModel.sunshineError
        case .catalog:
            return viewModel.error
        }
    }

    private var emptyIcon: String {
        if emptyError != nil {
            return "exclamationmark.triangle"
        }
        return scope == .sunshine ? "desktopcomputer" : "books.vertical"
    }

    private var searchPrompt: String {
        switch scope {
        case .ready:
            return "Search ready games"
        case .sunshine:
            return "Search Sunshine apps"
        case .catalog:
            return "Search GFN catalog"
        }
    }
}

// MARK: - Shared Box Art

struct GameBoxArt: View {
    let url: String?
    let title: String

    var body: some View {
        CachedRemoteImage(url: url.flatMap { URL(string: $0) }) { image in
            image
                .resizable()
                .aspectRatio(2/3, contentMode: .fill)
        } placeholder: {
                GameBoxArtFallback(title: title)
                    .shimmer()
        }
        .aspectRatio(2/3, contentMode: .fit)
        .clipShape(Rectangle())
    }
}

private struct GameBoxArtFallback: View {
    let title: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.12, blue: 0.13),
                    Color(red: 0.06, green: 0.09, blue: 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 14) {
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.26))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(4)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
            }
        }
        .aspectRatio(2/3, contentMode: .fit)
    }
}

// MARK: - Game Card Label (shared)

struct GameCardLabel: View {
    let game: GameInfo
    var isActive: Bool = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CachedRemoteImage(url: game.boxArtUrl.flatMap { URL(string: $0) }) { image in
                image
                    .resizable()
                    .aspectRatio(2/3, contentMode: .fill)
            } placeholder: {
                GameBoxArtFallback(title: game.title)
                    .shimmer()
            }
            .aspectRatio(2/3, contentMode: .fit)
            .clipShape(Rectangle())

            if isActive {
                GlassBadge(text: "Active", systemImage: "dot.radiowaves.left.and.right", tone: .primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            if let sourceBadge = LaunchSourceBadge(game: game) {
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.18)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 58)
                }
                .clipShape(Rectangle())

                LaunchSourceIconBadge(source: sourceBadge)
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .aspectRatio(2/3, contentMode: .fit)
        .contentShape(Rectangle())
    }
}

struct LaunchSourceBadge {
    let symbol: String
    let accessibilityLabel: String

    init?(game: GameInfo) {
        if game.isXCloudGame {
            symbol = "xbox.logo"
            accessibilityLabel = "Xbox Cloud Gaming launch"
        } else if game.isSunshineGame {
            symbol = "sun.max.fill"
            accessibilityLabel = "Sunshine launch"
        } else if !game.variants.isEmpty {
            symbol = "bolt.fill"
            let storeName = game.variants.first?.storeName ?? "GeForce NOW"
            accessibilityLabel = "\(storeName) launch"
        } else {
            return nil
        }
    }
}

struct LaunchSourceIconBadge: View {
    let source: LaunchSourceBadge

    var body: some View {
        Image(systemName: source.symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: 28, height: 28)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(Circle().fill(.white.opacity(0.055)))
            )
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
            .accessibilityLabel(source.accessibilityLabel)
    }
}

// MARK: - Game Card (used on Home rows)

struct GameCardView: View {
    let game: GameInfo
    var isActive: Bool = false
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            GameCardLabel(game: game, isActive: isActive)
        }
        .aspectRatio(2/3, contentMode: .fit)
        .buttonStyle(SquareGameCardButtonStyle())
        .gameContextMenu(for: game)
    }
}

// MARK: - Library Card

struct LibraryCardView: View {
    let game: GameInfo
    let isFavorite: Bool
    let onFavoriteToggle: () -> Void
    let onPlay: () -> Void

    var body: some View {
        Button(action: onPlay) {
            GameCardLabel(game: game)
        }
        .buttonStyle(SquareGameCardButtonStyle())
    }
}

struct SquareGameCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .clipShape(Rectangle())
            .contentShape(Rectangle())
            .overlay {
                Rectangle()
                    .strokeBorder(.white.opacity(isFocused ? 0.82 : 0), lineWidth: isFocused ? 5 : 0)
            }
            .shadow(color: .black.opacity(isFocused ? 0.32 : 0.16), radius: isFocused ? 18 : 8, y: isFocused ? 10 : 4)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .scaleEffect(configuration.isPressed ? 0.985 : (isFocused ? 1.04 : 1))
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}
