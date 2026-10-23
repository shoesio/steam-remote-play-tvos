import SwiftUI

@main
struct SteamTVApp: App {
    @StateObject private var model = DiscoveryModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            HostSelectionView(model: model)
                .task { model.start() }
                .onOpenURL { model.open($0) }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.start() } else if phase == .background { model.stop() }
                }
        }
    }
}
