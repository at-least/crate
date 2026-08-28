import SwiftUI
import UniformTypeIdentifiers
import MuCore
import MuKit

/// 主畫面（≈ Android MainActivity）：
/// 無庫 → 歡迎頁挑資料夾；有庫 → 音樂庫（搜尋、清單卡、專輯封面網格）；
/// 專輯/清單 → 封面頭部 + 播放/釘選 + 音軌列；底部浮動迷你播放卡 → 點開「現正播放」。
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var path: [Route] = []
    @State private var showPicker = false
    @State private var showNowPlaying = false

    enum Route: Hashable {
        case album(String)
        case playlist(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            root
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .album(let id):
                        AlbumDetail(albumId: id, player: model.player)
                    case .playlist(let name):
                        PlaylistDetail(name: name, player: model.player)
                    }
                }
        }
        // 迷你播放卡以 safeAreaInset 掛在 NavigationStack 外：所有頁面內容自動避開，推入頁不會蓋住它。
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MiniPlayerHost(player: model.player) { showNowPlaying = true }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(player: model.player)
        }
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                path.removeAll()
                model.open(url: url)
            }
        }
    }

    @ViewBuilder private var root: some View {
        if model.ui.rootPath == nil {
            WelcomeView { showPicker = true }
                .toolbar(.hidden, for: .navigationBar)
        } else if model.ui.scanning && model.ui.albums.isEmpty && model.ui.playlists.isEmpty {
            ScanningView()
                .navigationTitle("音樂庫")
        } else {
            LibraryView(path: $path) { showPicker = true }
        }
    }
}

// MARK: - 歡迎 / 掃描

private struct WelcomeView: View {
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 96)
                    .shadow(color: Color.accentColor.opacity(0.35), radius: 20, y: 10)
                Image(systemName: "music.note")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Mu")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .padding(.top, 28)
            Text("把雲端資料夾當成音樂庫。\n只讀不寫，隨處播放，釘選離線。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer()
            Button(action: onPick) {
                Label("選擇音樂資料夾", systemImage: "folder")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("支援 MP3 · FLAC · M4A · OGG · WAV，播放清單讀取 .m3u8")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 14)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }
}

private struct ScanningView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView().controlSize(.large)
            Text("正在掃描音樂庫…").font(.headline)
            Text("第一次掃描會讀取每個檔案的標籤，稍候片刻。")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 音樂庫

private struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var path: [ContentView.Route]
    let onPickFolder: () -> Void
    @State private var query = ""

    private var q: String { query.trimmingCharacters(in: .whitespaces) }

    private var albums: [Album] {
        guard !q.isEmpty else { return model.ui.albums }
        return model.ui.albums.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.albumArtist.localizedCaseInsensitiveContains(q)
        }
    }

    private var playlists: [AppModel.PlaylistUi] {
        guard !q.isEmpty else { return model.ui.playlists }
        return model.ui.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if !playlists.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "清單", count: playlists.count)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(playlists, id: \.name) { pl in
                                    PlaylistCard(playlist: pl) { path.append(.playlist(pl.name)) }
                                }
                            }
                            .padding(.horizontal, MuTheme.pageInset)
                        }
                    }
                }
                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "專輯", count: albums.count)
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: MuTheme.gridSpacing)],
                            alignment: .leading, spacing: 22
                        ) {
                            ForEach(albums, id: \.id) { album in
                                AlbumCard(album: album) { path.append(.album(album.id)) }
                            }
                        }
                        .padding(.horizontal, MuTheme.pageInset)
                    }
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 24)
        }
        .overlay {
            if albums.isEmpty && playlists.isEmpty {
                EmptyLibrary(searching: !q.isEmpty)
            }
        }
        .navigationTitle("音樂庫")
        .searchable(text: $query, prompt: "搜尋專輯、藝人或清單")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.ui.scanning {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("掃描中")
                } else {
                    Menu {
                        Button {
                            model.rescan()
                        } label: {
                            Label("重新掃描", systemImage: "arrow.clockwise")
                        }
                        Button(action: onPickFolder) {
                            Label("更換資料夾", systemImage: "folder")
                        }
                        if let root = model.ui.rootPath {
                            Section(URL(fileURLWithPath: root).lastPathComponent) { EmptyView() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("更多")
                }
            }
        }
    }
}

private struct EmptyLibrary: View {
    let searching: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: searching ? "magnifyingglass" : "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text(searching ? "沒有符合的結果" : "資料夾裡還沒有音樂")
                .font(.headline)
            if !searching {
                Text("把音樂放進資料夾後，從右上角選單重新掃描。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
    }
}

private struct AlbumCard: View {
    @EnvironmentObject private var model: AppModel
    let album: Album
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkImage(key: album.id, url: model.artworkURL(for: album.id),
                             loader: model.artwork, cornerRadius: MuTheme.radiusM)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(album.albumArtist + (album.year.map { " · \($0)" } ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct PlaylistCard: View {
    let playlist: AppModel.PlaylistUi
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PlaceholderArt(key: "pl:" + playlist.name, symbol: "music.note.list")
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: MuTheme.radiusS, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(playlist.tracks.count) 首")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 200)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: MuTheme.radiusM, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: MuTheme.radiusM, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 專輯 / 清單詳情

/// 專輯檢視：封面頭部 + 播放/釘選 + 音軌列（可見軌 = available 或已釘，來源消失仍可播）。
private struct AlbumDetail: View {
    @EnvironmentObject private var model: AppModel
    let albumId: String
    /// 播放中列高亮需直訂 player；AppModel 的 @Published 不涵蓋 player 內部狀態。
    @ObservedObject var player: PlayerManager

    var body: some View {
        if let album = model.ui.albums.first(where: { $0.id == albumId }) {
            let tracks = model.ui.tracksByAlbum[album.id] ?? []
            ScrollView {
                VStack(spacing: 0) {
                    ArtworkImage(key: album.id, url: model.artworkURL(for: album.id),
                                 loader: model.artwork, cornerRadius: MuTheme.radiusL)
                        .frame(width: 236, height: 236)
                        .shadow(color: .black.opacity(0.22), radius: 22, y: 12)
                        .padding(.top, 8)

                    VStack(spacing: 4) {
                        Text(album.name)
                            .font(.title2.weight(.bold))
                            .multilineTextAlignment(.center)
                        Text(album.albumArtist)
                            .font(.headline)
                            .foregroundStyle(Color.accentColor)
                        Text(meta(album, tracks))
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, 22)
                    .padding(.horizontal, MuTheme.pageInset)

                    HStack(spacing: 12) {
                        PlayAllButton { model.play(tracks, startIndex: 0) }
                            .disabled(tracks.isEmpty)
                        PinButton(tracks: tracks, pinStates: model.ui.pinStates,
                                  pin: { model.pinAlbum(albumId) },
                                  unpin: { model.unpinAlbum(albumId) })
                            .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                    .padding(.horizontal, MuTheme.pageInset)
                    .padding(.top, 20)
                    .padding(.bottom, 12)

                    TrackList(count: tracks.count) { i in
                        let t = tracks[i]
                        TrackRow(index: i, number: t.trackNo ?? (i + 1), title: t.title,
                                 subtitle: t.artist != album.albumArtist ? t.artist : nil,
                                 durationMs: t.durationMs,
                                 isPlaying: player.nowTrack?.id == t.id,
                                 isOffline: model.ui.pinStates[t.id] == .done) {
                            model.play(tracks, startIndex: i)
                        }
                    }
                    TrackSummary(tracks: tracks)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            // unpin 後專輯可能整個消失（全離線軌被濾掉）
            GoneView(text: "專輯已無可播軌")
        }
    }

    private func meta(_ album: Album, _ tracks: [Track]) -> String {
        var parts: [String] = []
        if let y = album.year { parts.append(String(y)) }
        if let f = tracks.first?.format.uppercased(), !f.isEmpty { parts.append(f) }
        parts.append("\(tracks.count) 首")
        return parts.joined(separator: " · ")
    }
}

private struct PlaylistDetail: View {
    @EnvironmentObject private var model: AppModel
    let name: String
    @ObservedObject var player: PlayerManager

    var body: some View {
        if let pl = model.ui.playlists.first(where: { $0.name == name }) {
            ScrollView {
                VStack(spacing: 0) {
                    HStack(alignment: .center, spacing: 16) {
                        PlaceholderArt(key: "pl:" + pl.name, symbol: "music.note.list")
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: MuTheme.radiusM, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pl.name)
                                .font(.title2.weight(.bold))
                                .lineLimit(2)
                            Text("播放清單 · \(pl.tracks.count) 首 · \(fmtTotal(pl.tracks))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, MuTheme.pageInset)
                    .padding(.top, 8)

                    PlayAllButton { model.play(pl.tracks, startIndex: 0) }
                        .disabled(pl.tracks.isEmpty)
                        .controlSize(.large)
                        .padding(.horizontal, MuTheme.pageInset)
                        .padding(.top, 20)
                        .padding(.bottom, 12)

                    TrackList(count: pl.tracks.count) { i in
                        let t = pl.tracks[i]
                        TrackRow(index: i, number: i + 1, title: t.title,
                                 subtitle: t.artist + " · " + t.album,
                                 durationMs: t.durationMs,
                                 isPlaying: player.nowTrack?.id == t.id,
                                 isOffline: model.ui.pinStates[t.id] == .done) {
                            model.play(pl.tracks, startIndex: i)
                        }
                    }
                    TrackSummary(tracks: pl.tracks)
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        } else {
            GoneView(text: "清單已無可播軌")
        }
    }
}

private struct GoneView: View {
    let text: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(text).font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 迷你播放卡

/// hasQueue 的 gate 必須在訂閱 PlayerManager 的視圖內——放在只訂 AppModel 的視圖裡永遠不會重算。
private struct MiniPlayerHost: View {
    @ObservedObject var player: PlayerManager
    let onOpen: () -> Void

    var body: some View {
        if player.hasQueue {
            MiniPlayer(player: player, onOpen: onOpen)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 浮動卡片：封面縮圖、標題/藝人、播/暫、下一首；底緣細進度線；點卡片開「現正播放」。
private struct MiniPlayer: View {
    @ObservedObject var player: PlayerManager
    @EnvironmentObject private var model: AppModel
    let onOpen: () -> Void

    var body: some View {
        let key = player.nowTrack?.albumId ?? ""
        HStack(spacing: 12) {
            ArtworkImage(key: key, url: player.nowTrack.map { model.artworkURL(for: $0.albumId) } ?? nil,
                         loader: model.artwork, cornerRadius: MuTheme.radiusS)
                .frame(width: 46, height: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.nowTitle ?? "")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("player.title")
                Text(player.nowArtist ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
            .accessibilityIdentifier("player.toggle")
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一首")
            .accessibilityIdentifier("player.next")
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                let frac = player.duration > 0 ? min(1, player.elapsed / player.duration) : 0
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(0, (g.size.width - 24) * frac), height: 2)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 4)
            }
            .allowsHitTesting(false)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}
