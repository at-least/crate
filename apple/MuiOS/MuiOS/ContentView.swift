import SwiftUI
import UniformTypeIdentifiers
import MuCore
import MuKit

/// 主畫面（≈ Android MainActivity）。
///
/// 資訊架構（HIG：一個層級一件事）：
/// 資料庫（分段控制：專輯／清單）→ 專輯/清單詳情 → 迷你播放列 → 現正播放 sheet。
/// 搜尋中忽略分段，兩類同時列出（各自過濾）；沒有清單時完全不顯示分段控制。
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
        // 迷你播放列以 safeAreaInset 掛在 NavigationStack 外：所有頁面內容自動避開，推入頁不會蓋住它。
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
                .navigationTitle("資料庫")
        } else {
            LibraryView(path: $path) { showPicker = true }
        }
    }
}

// MARK: - 歡迎 / 掃描

/// 首次啟動：一個符號、一句說明、一個主要動作（HIG：每個畫面只有一個主 CTA）。
private struct WelcomeView: View {
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Mu")
                .font(.largeTitle.weight(.bold))
                .padding(.top, 16)
            Text("把雲端資料夾當成音樂庫。\n只讀不寫，隨處播放，釘選離線。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
            Spacer(minLength: 24)
            Button(action: onPick) {
                Text("選擇音樂資料夾")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("支援 MP3 · FLAC · M4A · OGG · WAV，播放清單讀取 .m3u8")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
    }
}

private struct ScanningView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("正在掃描資料庫")
                .font(.headline)
            Text("第一次掃描會讀取每個檔案的標籤，稍候片刻。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 資料庫

private struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var path: [ContentView.Route]
    let onPickFolder: () -> Void
    @State private var query = ""
    @State private var tab: Tab = .albums

    private enum Tab: Hashable {
        case albums, playlists
    }

    private var q: String { query.trimmingCharacters(in: .whitespaces) }
    private var searching: Bool { !q.isEmpty }

    private var albums: [Album] {
        guard searching else { return model.ui.albums }
        return model.ui.albums.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.albumArtist.localizedCaseInsensitiveContains(q)
        }
    }

    private var playlists: [AppModel.PlaylistUi] {
        guard searching else { return model.ui.playlists }
        return model.ui.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// 只有一種內容時分段控制沒有意義——直接不顯示。
    private var showsPicker: Bool { !searching && !model.ui.playlists.isEmpty }
    private var showsAlbums: Bool { searching ? !albums.isEmpty : (tab == .albums || model.ui.playlists.isEmpty) }
    private var showsPlaylists: Bool { searching ? !playlists.isEmpty : (tab == .playlists && !model.ui.playlists.isEmpty) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                if showsPicker {
                    Picker("顯示", selection: $tab) {
                        Text("專輯").tag(Tab.albums)
                        Text("清單").tag(Tab.playlists)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, MuTheme.pageInset)
                    .padding(.top, 4)
                }
                if showsPlaylists {
                    VStack(alignment: .leading, spacing: 0) {
                        if searching {
                            SectionHeader(title: "清單", count: playlists.count)
                                .padding(.bottom, 4)
                        }
                        ForEach(Array(playlists.enumerated()), id: \.element.name) { i, pl in
                            PlaylistRow(playlist: pl) { path.append(.playlist(pl.name)) }
                            if i < playlists.count - 1 {
                                Divider().padding(.leading, MuTheme.pageInset + 68)
                            }
                        }
                    }
                }
                if showsAlbums {
                    VStack(alignment: .leading, spacing: 12) {
                        if searching {
                            SectionHeader(title: "專輯", count: albums.count)
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), spacing: MuTheme.gridSpacing)],
                            alignment: .leading, spacing: 20
                        ) {
                            ForEach(albums, id: \.id) { album in
                                AlbumCard(album: album) { path.append(.album(album.id)) }
                            }
                        }
                        .padding(.horizontal, MuTheme.pageInset)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .overlay {
            if albums.isEmpty && playlists.isEmpty {
                EmptyLibrary(searching: searching)
            }
        }
        .navigationTitle("資料庫")
        .searchable(text: $query, prompt: "專輯、藝人或清單")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if model.ui.scanning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("掃描中")
                } else {
                    Menu {
                        Section(folderName) {
                            Button {
                                model.rescan()
                            } label: {
                                Label("重新掃描", systemImage: "arrow.clockwise")
                            }
                            Button(action: onPickFolder) {
                                Label("更換資料夾…", systemImage: "folder")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("資料庫選項")
                }
            }
        }
    }

    private var folderName: String {
        model.ui.rootPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "資料夾"
    }
}

private struct EmptyLibrary: View {
    let searching: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: searching ? "magnifyingglass" : "music.note.list")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(searching ? "沒有符合的結果" : "資料夾裡還沒有音樂")
                .font(.title3.weight(.semibold))
                .padding(.top, 4)
            Text(searching ? "換個關鍵字試試。" : "把音樂放進資料夾後，從右上角選單重新掃描。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
    }
}

/// 專輯卡：封面即內容，文字降到最低（HIG deference）。
private struct AlbumCard: View {
    @EnvironmentObject private var model: AppModel
    let album: Album
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                ArtworkImage(key: album.id, url: model.artworkURL(for: album.id),
                             loader: model.artwork, cornerRadius: MuTheme.radiusM)
                    .shadow(color: .black.opacity(0.08), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.name)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(album.albumArtist + (album.year.map { " · \($0)" } ?? ""))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 清單列：整列可點（≥44pt），右側 chevron 表示可推入。
private struct PlaylistRow: View {
    let playlist: AppModel.PlaylistUi
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                PlaceholderArt(key: "pl:" + playlist.name, symbol: "music.note.list")
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: MuTheme.radiusS, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(playlist.tracks.count) 首")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, MuTheme.pageInset)
            .padding(.vertical, 8)
            .frame(minHeight: MuTheme.hitTarget)
            .contentShape(Rectangle())
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
                        .frame(width: 240, height: 240)
                        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
                        .padding(.top, 8)

                    VStack(spacing: 2) {
                        Text(album.name)
                            .font(.title3.weight(.semibold))
                            .multilineTextAlignment(.center)
                        Text(album.albumArtist)
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .multilineTextAlignment(.center)
                        Text(meta(album, tracks))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(.top, 20)
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
                    .buttonBorderShape(.capsule)
                    .padding(.horizontal, MuTheme.pageInset)
                    .padding(.top, 20)
                    .padding(.bottom, 8)

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
                            .shadow(color: .black.opacity(0.12), radius: 10, y: 5)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(pl.name)
                                .font(.title3.weight(.semibold))
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
                        .buttonBorderShape(.capsule)
                        .padding(.horizontal, MuTheme.pageInset)
                        .padding(.top, 20)
                        .padding(.bottom, 8)

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
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(text)
                .font(.headline)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 迷你播放列

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

/// 浮動列：封面縮圖、標題/藝人、播/暫、下一首；底緣細進度線；點整列開「現正播放」。
private struct MiniPlayer: View {
    @ObservedObject var player: PlayerManager
    @EnvironmentObject private var model: AppModel
    let onOpen: () -> Void

    var body: some View {
        let key = player.nowTrack?.albumId ?? ""
        HStack(spacing: 12) {
            ArtworkImage(key: key, url: player.nowTrack.map { model.artworkURL(for: $0.albumId) } ?? nil,
                         loader: model.artwork, cornerRadius: MuTheme.radiusS)
                .frame(width: 44, height: 44)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(player.nowTitle ?? "")
                    .font(.subheadline)
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
                    .font(.title3)
                    .frame(width: MuTheme.hitTarget, height: MuTheme.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
            .accessibilityIdentifier("player.toggle")
            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.body)
                    .frame(width: MuTheme.hitTarget, height: MuTheme.hitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("下一首")
            .accessibilityIdentifier("player.next")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(alignment: .bottom) {
            GeometryReader { g in
                let frac = player.duration > 0 ? min(1, player.elapsed / player.duration) : 0
                Capsule()
                    .fill(Color.primary.opacity(0.35))
                    .frame(width: max(0, (g.size.width - 24) * frac), height: 2)
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 5)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityAction(named: "打開現正播放", onOpen)
    }
}
