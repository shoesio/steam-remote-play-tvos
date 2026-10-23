import SwiftUI

struct HostSelectionView: View {
    @ObservedObject var model: DiscoveryModel
    @State private var background: UIImage?
    @State private var logo: UIImage?
    private var selected: SteamHost? {
        model.hosts.first { $0.id == model.selectedHostID } ?? model.hosts.first(where: \.online) ?? model.hosts.first
    }
    var body: some View {
        Group {
            if model.videoFrame != nil || model.hasPyroFrame {
                MetalVideoView(mailbox: model.frameMailbox, statistics: model.videoDisplayStatistics, presented: model.videoPresented)
                    .ignoresSafeArea()
                    .onExitCommand { model.exitToHome() }
            } else if let game = model.loadingGame {
                GeometryReader { geometry in
                    ZStack {
                        if let background {
                            Image(uiImage: background).resizable().scaledToFill()
                                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                        } else {
                            LinearGradient(colors: [Color(red: 0.10, green: 0.17, blue: 0.24), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                        }
                        LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                        VStack(spacing: 22) {
                            Spacer()
                            if let logo {
                                Image(uiImage: logo).resizable().scaledToFit().frame(width: 560, height: 230)
                            } else {
                                Text(game.title).font(.largeTitle).multilineTextAlignment(.center).shadow(radius: 8)
                            }
                            Spacer()
                            controls
                        }.padding(.horizontal, 60).padding(.bottom, 70)
                    }
                }.ignoresSafeArea().preferredColorScheme(.dark)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(red: 0.10, green: 0.17, blue: 0.24), .black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    VStack(spacing: 28) {
                        Image("SteamMark").resizable().scaledToFit().frame(width: 190, height: 190)
                        Text("Steam Remote Play").font(.largeTitle)
                        controls
                    }.padding(60)
                }.ignoresSafeArea().preferredColorScheme(.dark)
            }
        }
        .task(id: model.loadingGame?.id) { loadArtwork() }
    }
    private func loadArtwork() {
        background = nil; logo = nil
        guard let game = model.loadingGame, let store = SteamRecentLibrary.store else { return }
        let paths = [game.background, "/art/\(game.id)/hero.png", "/art/\(game.id)/hero.jpg", game.hero]
        for path in paths.compactMap({ $0 }) {
            if let url = store.artworkURL(gameID: game.id, path: path), let image = UIImage(contentsOfFile: url.path) {
                background = image; break
            }
        }
        if let path = game.logo, let url = store.artworkURL(gameID: game.id, path: path) {
            logo = UIImage(contentsOfFile: url.path)
        }
    }
    @ViewBuilder private var controls: some View {
        if let pin = model.pairingPIN {
            Text(pin).font(.system(size: 90, weight: .bold, design: .monospaced))
            Text("Enter this PIN in Steam on your PC.")
            Button("Cancel") { model.cancelPairing(); model.cancelConnection() }
        } else {
            if model.connecting || !model.launcherError && model.message != "Disconnected" { ProgressView().tint(.white) }
            Text(model.message).font(.title3).multilineTextAlignment(.center).frame(maxWidth: 1000)
            if model.launcherError || model.message == "Disconnected" {
                Button(model.launcherError ? "Rejoin" : "Connect to Steam") { model.retry() }
            }
            if model.connecting { Button("Cancel") { model.cancelConnection() } }
            if model.hosts.count > 1, let selected {
                Picker("Computer", selection: Binding(get: { model.selectedHostID ?? selected.id }, set: { id in
                    model.cancelConnection(); model.selectedHostID = id
                    if let host = model.hosts.first(where: { $0.id == id }) { model.play(host) }
                })) { ForEach(model.hosts) { Text($0.status.hostname).tag($0.id) } }.frame(width: 560)
            }
        }
    }
}
