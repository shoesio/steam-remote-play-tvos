import SwiftUI

struct ProviderLibraryView: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let games: [GameInfo]
    var isLoading = false
    var errorMessage: String? = nil
    var emptyMessage = "No playable games were found for this service."
    var onReload: (() -> Void)? = nil
    let onPlay: (GameInfo) -> Void

    @Environment(GamesViewModel.self) private var viewModel
    @State private var searchText = ""
    @FocusState private var isStatusReloadFocused: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 40)
    ]

    private var filteredGames: [GameInfo] {
        let source = searchText.isEmpty
            ? games
            : games.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
        return source.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    header
                        .padding(.horizontal, 60)
                        .padding(.top, 36)
                    content
                }
                .padding(.bottom, 60)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 18) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .bold))
                .foregroundStyle(accent)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.largeTitle.bold())
                Text("\(filteredGames.count) playable games · \(subtitle)")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Search \(title)", text: $searchText)
                .textFieldStyle(.plain)
                .padding(.horizontal, 20)
                .frame(width: 380, height: 52)
                .background(.white.opacity(0.10), in: Capsule())
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && games.isEmpty {
            VStack(spacing: 20) {
                ProgressView().scaleEffect(1.5)
                Text("Loading \(title)…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage, games.isEmpty {
            status(icon: "exclamationmark.triangle.fill", title: "Couldn’t Load \(title)", message: errorMessage)
        } else if filteredGames.isEmpty {
            status(
                icon: searchText.isEmpty ? "rectangle.stack.badge.questionmark" : "magnifyingglass",
                title: searchText.isEmpty ? "No Playable Games" : "No Search Results",
                message: searchText.isEmpty ? emptyMessage : "No \(title) games match “\(searchText)”."
            )
        } else {
            gamesGrid
        }
    }

    private var gamesGrid: some View {
        LazyVGrid(columns: columns, spacing: 40) {
            ForEach(filteredGames) { game in
                Button {
                    onPlay(viewModel.gameWithPreferredStore(game))
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        GameCardLabel(game: viewModel.gameWithPreferredStore(game), isActive: viewModel.isSessionActive(for: game))
                        Text(game.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                            .padding(.horizontal, 12)
                    }
                    .background(.white.opacity(0.07), in: Rectangle())
                    .clipShape(Rectangle())
                }
                .buttonStyle(SquareGameCardButtonStyle())
                .gameContextMenu(for: game)
            }
        }
        .padding(.horizontal, 60)
        .padding(.vertical, 16)
        .focusSection()
    }

    private func status(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: icon).font(.system(size: 58)).foregroundStyle(.secondary)
            Text(title).font(.title2.bold())
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 720)
            if let onReload {
                Button("Reload") { onReload() }
                    .buttonStyle(AppActionButtonStyle(tone: .primary, minWidth: 180))
                    .focused($isStatusReloadFocused)
                    .defaultFocus($isStatusReloadFocused, true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
        .onAppear {
            guard onReload != nil else { return }
            DispatchQueue.main.async {
                isStatusReloadFocused = true
            }
        }
    }
}
