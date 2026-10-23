import SwiftUI

struct XCloudLibraryView: View {
    @Environment(XCloudAuthManager.self) private var auth
    @Environment(XCloudLibraryStore.self) private var store
    @Environment(GamesViewModel.self) private var viewModel
    let onPlay: (GameInfo) -> Void

    var body: some View {
        ProviderLibraryView(
            title: "Xbox Cloud Gaming",
            subtitle: "Included with your Xbox package",
            systemImage: "xbox.logo",
            accent: .green,
            games: store.gameInfos,
            isLoading: store.isLoading,
            errorMessage: store.errorMessage,
            emptyMessage: "No games included with this account’s Xbox Cloud Gaming package were returned.",
            onReload: {
                Task {
                    await store.load(auth: auth, force: true)
                    viewModel.setXCloudGames(
                        store.gameInfos,
                        newOnXCloud: store.newOnXCloudGameInfos,
                        mostPopular: store.mostPopularGameInfos
                    )
                }
            },
            onPlay: onPlay
        )
        .task {
            await store.load(auth: auth)
            viewModel.setXCloudGames(
                store.gameInfos,
                newOnXCloud: store.newOnXCloudGameInfos,
                mostPopular: store.mostPopularGameInfos
            )
        }
    }
}
