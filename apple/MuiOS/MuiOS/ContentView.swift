import SwiftUI
import UniformTypeIdentifiers
import MuCore

/// 主畫面（≈ Android MainActivity）：無庫 → 挑選資料夾；有庫 → 清單列 + 專輯網格；
/// 專輯/清單 → 音軌清單（釘選、離線標記）；底部迷你播放列（含 AirPlay 路由）。
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [Route] = []
    @State private var showPicker = false

    enum Route: Hashable {
        case album(String)
        case playlist(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                if model.ui.scanning {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("掃描中…")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.ui.rootPath == nil {
                    VStack(spacing: 12) {
                        Text("選擇你的音樂資料夾").font(.title3)
                        Button("選擇資料夾") { showPicker = true }
                            .buttonStyle(.borderedProminent)
                            .padding(.top, 16)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    libraryView
                }
            }
            .navigationTitle("Mu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.ui.rootPath != nil {
                    Button {
                        model.rescan()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重掃")
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    model.open(url: url)
                }
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .album(let id):
                    AlbumDetail(albumId: id)
                case .playlist(let name):
                    PlaylistDetail(name: name)
                }
            }
        }
        // 播放列掛 NavigationStack 外——掛在 root ZStack 時，推入的頁面蓋住 overlay
        .overlay(alignment: .bottom) {
            PlayerBarHost(player: model.player)
        }
    }

    private var libraryView: some View {
        ScrollView {
            if !model.ui.playlists.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(model.ui.playlists, id: \.name) { pl in
                            Button(pl.name) { path.append(.playlist(pl.name)) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                ForEach(model.ui.albums, id: \.id) { album in
                    AlbumCardButton(album: album) { path.append(.album(album.id)) }
                }
            }
            .padding(8)
        }
    }
}

private struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(album.name)
                .font(.headline)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(album.albumArtist)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("\(album.trackCount) 軌" + (album.year.map { " · \($0)" } ?? ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }
}

private struct AlbumCardButton: View {
    let album: Album
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            AlbumCard(album: album)
        }
        .buttonStyle(.plain)
    }
}

/// 專輯檢視：釘選列 + 音軌清單（可見軌 = available 或已釘，來源消失仍可播）。
private struct AlbumDetail: View {
    @EnvironmentObject private var model: AppModel
    let albumId: String

    var body: some View {
        if let album = model.ui.albums.first(where: { $0.id == albumId }) {
            let tracks = model.ui.tracksByAlbum[album.id] ?? []
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(album.albumArtist + (album.year.map { " · \($0)" } ?? ""))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    pinChip(tracks: tracks)
                        .padding(.horizontal, 16)
                    TrackListView(tracks: tracks, offlineIds: offlineDone) { i in
                        print("[MU] onPlay row \(i)")
                        model.play(tracks, startIndex: i)
                    }
                }
            }
            .navigationTitle(album.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            // unpin 後專輯可能整個消失（全離線軌被濾掉）
            Text("專輯已無可播軌")
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var offlineDone: Set<String> {
        Set(model.ui.pinStates.filter { $0.value == .done }.keys)
    }

    private func pinChip(tracks: [Track]) -> some View {
        let states = tracks.compactMap { model.ui.pinStates[$0.id] }
        let done = states.filter { $0 == .done }.count
        let pending = states.filter { $0.isPending }.count
        let failed = states.filter { $0 == .failed }.count
        let label: String
        switch true {
        case tracks.isEmpty:
            label = "無軌"
        case done == tracks.count:
            label = "已釘選（\(tracks.count) 軌，點擊取消）"
        case done + pending > 0:
            label = "釘選中 \(done)/\(tracks.count)" + (failed > 0 ? " · \(failed) 失敗" : "")
        case failed > 0:
            label = "釘選失敗 \(failed)/\(tracks.count)（點擊重試）"
        default:
            label = "釘選離線（\(tracks.count) 軌）"
        }
        return Button {
            if !tracks.isEmpty && done == tracks.count {
                model.unpinAlbum(albumId)
            } else {
                model.pinAlbum(albumId)
            }
        } label: {
            Text(label)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier("pinChip")
    }
}

private struct PlaylistDetail: View {
    @EnvironmentObject private var model: AppModel
    let name: String

    var body: some View {
        if let pl = model.ui.playlists.first(where: { $0.name == name }) {
            TrackListView(tracks: pl.tracks, offlineIds: []) { i in
                model.play(pl.tracks, startIndex: i)
            }
            .navigationTitle(pl.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            Text("清單已無可播軌")
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 音軌清單（專輯/清單共用）。
private struct TrackListView: View {
    let tracks: [Track]
    let offlineIds: Set<String>
    let onPlay: (Int) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                Button {
                    onPlay(i)
                } label: {
                    HStack {
                        Text((t.trackNo.map { "\($0). " } ?? "") + t.title)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                        if offlineIds.contains(t.id) {
                            Text("離線")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.trailing, 8)
                        }
                        Text(fmtDuration(t.durationMs))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(minWidth: 36, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 播放列宿主：hasQueue 的 gate 也必須在訂閱 PlayerManager 的視圖內——
/// 放在 ContentView（只訂 AppModel）body 裡永遠不會重算，播放列長不出來。
private struct PlayerBarHost: View {
    @ObservedObject var player: PlayerManager

    var body: some View {
        if player.hasQueue {
            PlayerBar(player: player)
        }
    }
}

/// 底部迷你播放列：播/暫、下一首、AirPlay 路由。
/// @ObservedObject 直訂 PlayerManager——AppModel 的 @Published 不涵蓋 player 內部狀態。
private struct PlayerBar: View {
    @ObservedObject var player: PlayerManager

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(player.nowTitle ?? "")
                    .font(.subheadline)
                    .lineLimit(1)
                Text(player.nowArtist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            RoutePicker()
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
            }
            .accessibilityIdentifier("player.toggle")
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
            }
            .accessibilityIdentifier("player.next")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

private func fmtDuration(_ ms: Int?) -> String {
    guard let ms, ms >= 0 else { return "" }
    return String(format: "%d:%02d", ms / 60000, ms / 1000 % 60)
}
