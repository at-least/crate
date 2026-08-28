import SwiftUI
import MuCore
import MuKit

/// 選單列 popover（400×560）：無庫 → 歡迎頁；有庫 → 搜尋列 + 清單/專輯（縮圖）→ 音軌；
/// 底部常駐播放列（封面、上一首/播/下一首、可點擊進度條）。
struct MacContentView: View {
    @EnvironmentObject private var model: MacModel
    @State private var path: [Route] = []

    enum Route: Hashable {
        case album(String)
        case playlist(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack(path: $path) {
                root
                    .navigationDestination(for: Route.self) { route in
                        switch route {
                        case .album(let id):
                            MacAlbumDetail(albumId: id, player: model.player)
                        case .playlist(let name):
                            MacPlaylistDetail(name: name, player: model.player)
                        }
                    }
            }
            MacPlayerBarHost(player: model.player)
        }
    }

    @ViewBuilder private var root: some View {
        if model.ui.rootPath == nil {
            VStack(spacing: 0) {
                MacHeader(title: "Mu") { EmptyView() }
                MacWelcome { pickFolder() }
            }
        } else if model.ui.scanning && model.ui.albums.isEmpty && model.ui.playlists.isEmpty {
            VStack(spacing: 0) {
                MacHeader(title: "音樂庫") { EmptyView() }
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在掃描音樂庫…").font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                MacHeader(title: "音樂庫") {
                    if model.ui.scanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Menu {
                            Button {
                                model.rescan()
                            } label: {
                                Label("重新掃描", systemImage: "arrow.clockwise")
                            }
                            Button {
                                pickFolder()
                            } label: {
                                Label("更換資料夾…", systemImage: "folder")
                            }
                            if let root = model.ui.rootPath {
                                Divider()
                                Text(URL(fileURLWithPath: root).lastPathComponent)
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("更多")
                        .help("重掃 / 更換資料夾")
                    }
                }
                MacLibrary(path: $path)
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "選擇音樂資料夾"
        if panel.runModal() == .OK, let url = panel.url {
            path.removeAll()
            model.open(url: url)
        }
    }
}

// MARK: - 頂欄

/// popover 內無系統標題列/工具列——自畫頂欄：返回鍵（NavigationStack 內頁）、標題、右側動作、退出。
private struct MacHeader<Trailing: View>: View {
    let title: String
    var showBack = false
    @ViewBuilder let trailing: () -> Trailing
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 8) {
            if showBack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("返回")
                .accessibilityIdentifier("mac.back")
            }
            Text(title)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            trailing()
            // 選單列常駐 app 無 Dock/主選單——唯一的退出入口
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("退出")
            .accessibilityIdentifier("mac.quit")
            .help("退出 Mu")
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }
}

// MARK: - 歡迎

private struct MacWelcome: View {
    let onPick: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 72, height: 72)
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 14, y: 8)
                Image(systemName: "music.note")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Mu")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .padding(.top, 18)
            Text("把資料夾當成音樂庫。\n只讀不寫，隨處播放，釘選離線。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Spacer()
            Button(action: onPick) {
                Label("選擇音樂資料夾…", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Text("MP3 · FLAC · M4A · OGG · WAV · .m3u8")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
        }
        .padding(28)
    }
}

// MARK: - 音樂庫

private struct MacLibrary: View {
    @EnvironmentObject private var model: MacModel
    @Binding var path: [MacContentView.Route]
    @State private var query = ""

    private var q: String { query.trimmingCharacters(in: .whitespaces) }

    private var albums: [Album] {
        guard !q.isEmpty else { return model.ui.albums }
        return model.ui.albums.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.albumArtist.localizedCaseInsensitiveContains(q)
        }
    }

    private var playlists: [MacModel.PlaylistUi] {
        guard !q.isEmpty else { return model.ui.playlists }
        return model.ui.playlists.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Divider()
            if albums.isEmpty && playlists.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: q.isEmpty ? "music.note.list" : "magnifyingglass")
                        .font(.system(size: 30))
                        .foregroundStyle(.tertiary)
                    Text(q.isEmpty ? "資料夾裡還沒有音樂" : "沒有符合的結果")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !playlists.isEmpty {
                        Section("清單") {
                            ForEach(playlists, id: \.name) { pl in
                                NavigationLink(value: MacContentView.Route.playlist(pl.name)) {
                                    HStack(spacing: 10) {
                                        PlaceholderArt(key: "pl:" + pl.name, symbol: "music.note.list")
                                            .frame(width: 36, height: 36)
                                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(pl.name).lineLimit(1)
                                            Text("\(pl.tracks.count) 首")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                    Section("專輯") {
                        ForEach(albums, id: \.id) { album in
                            NavigationLink(value: MacContentView.Route.album(album.id)) {
                                HStack(spacing: 10) {
                                    ArtworkImage(key: album.id, url: model.artworkURL(for: album.id),
                                                 loader: model.artwork, cornerRadius: 6)
                                        .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(album.name).fontWeight(.medium).lineLimit(1)
                                        Text(album.albumArtist
                                             + (album.year.map { " · \($0)" } ?? "")
                                             + " · \(album.trackCount) 首")
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("搜尋專輯、藝人或清單", text: $text)
                .textFieldStyle(.plain)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 詳情

private struct MacAlbumDetail: View {
    @EnvironmentObject private var model: MacModel
    let albumId: String
    @ObservedObject var player: MacPlayer

    var body: some View {
        if let album = model.ui.albums.first(where: { $0.id == albumId }) {
            let tracks = model.ui.tracksByAlbum[album.id] ?? []
            VStack(spacing: 0) {
                MacHeader(title: album.name, showBack: true) { EmptyView() }
                HStack(alignment: .top, spacing: 14) {
                    ArtworkImage(key: album.id, url: model.artworkURL(for: album.id),
                                 loader: model.artwork, cornerRadius: 10)
                        .frame(width: 108, height: 108)
                        .shadow(color: .black.opacity(0.2), radius: 10, y: 5)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(album.name).font(.title3.weight(.bold)).lineLimit(2)
                        Text(album.albumArtist).foregroundStyle(Color.accentColor).lineLimit(1)
                        Text(meta(album, tracks)).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 6)
                        HStack(spacing: 8) {
                            Button {
                                model.play(tracks, startIndex: 0)
                            } label: {
                                Label("播放", systemImage: "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(tracks.isEmpty)
                            MacPinButton(tracks: tracks, pinStates: model.ui.pinStates,
                                         pin: { model.pinAlbum(albumId) },
                                         unpin: { model.unpinAlbum(albumId) })
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 108)
                .padding(14)
                Divider()
                List {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, t in
                        MacTrackRow(number: t.trackNo ?? (i + 1), title: t.title,
                                    subtitle: t.artist != album.albumArtist ? t.artist : nil,
                                    durationMs: t.durationMs,
                                    isPlaying: player.nowTrack?.id == t.id,
                                    isOffline: model.ui.pinStates[t.id] == .done) {
                            model.play(tracks, startIndex: i)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .navigationBarBackButtonHidden(true)
        } else {
            VStack(spacing: 0) {
                MacHeader(title: "專輯", showBack: true) { EmptyView() }
                Text("專輯已無可播軌").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationBarBackButtonHidden(true)
        }
    }

    private func meta(_ album: Album, _ tracks: [Track]) -> String {
        var parts: [String] = []
        if let y = album.year { parts.append(String(y)) }
        if let f = tracks.first?.format.uppercased(), !f.isEmpty { parts.append(f) }
        parts.append("\(tracks.count) 首 · \(fmtTotal(tracks))")
        return parts.joined(separator: " · ")
    }
}

private struct MacPlaylistDetail: View {
    @EnvironmentObject private var model: MacModel
    let name: String
    @ObservedObject var player: MacPlayer

    var body: some View {
        if let pl = model.ui.playlists.first(where: { $0.name == name }) {
            VStack(spacing: 0) {
                MacHeader(title: pl.name, showBack: true) { EmptyView() }
                HStack(spacing: 14) {
                    PlaceholderArt(key: "pl:" + pl.name, symbol: "music.note.list")
                        .frame(width: 72, height: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(pl.name).font(.title3.weight(.bold)).lineLimit(2)
                        Text("播放清單 · \(pl.tracks.count) 首 · \(fmtTotal(pl.tracks))")
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            model.play(pl.tracks, startIndex: 0)
                        } label: {
                            Label("播放", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(pl.tracks.isEmpty)
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                Divider()
                List {
                    ForEach(Array(pl.tracks.enumerated()), id: \.element.id) { i, t in
                        MacTrackRow(number: i + 1, title: t.title,
                                    subtitle: t.artist + " · " + t.album,
                                    durationMs: t.durationMs,
                                    isPlaying: player.nowTrack?.id == t.id,
                                    isOffline: model.ui.pinStates[t.id] == .done) {
                            model.play(pl.tracks, startIndex: i)
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
            .navigationBarBackButtonHidden(true)
        } else {
            VStack(spacing: 0) {
                MacHeader(title: "清單", showBack: true) { EmptyView() }
                Text("清單已無可播軌").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationBarBackButtonHidden(true)
        }
    }
}

private struct MacTrackRow: View {
    let number: Int
    let title: String
    var subtitle: String? = nil
    let durationMs: Int?
    let isPlaying: Bool
    let isOffline: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text("\(number)")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, alignment: .center)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if isOffline {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("離線")
                        .help("已釘選離線")
                }
                Text(fmtDuration(durationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 34, alignment: .trailing)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 釘選按鈕（label 語意同 iOS：短標籤 + 完整 accessibility 句）。
private struct MacPinButton: View {
    let tracks: [Track]
    let pinStates: [String: PinManager.PinState]
    let pin: () -> Void
    let unpin: () -> Void

    private var done: Int { tracks.filter { pinStates[$0.id] == .done }.count }
    private var pending: Int { tracks.filter { pinStates[$0.id]?.isPending == true }.count }
    private var failed: Int { tracks.filter { pinStates[$0.id] == .failed }.count }
    private var allDone: Bool { !tracks.isEmpty && done == tracks.count }

    private var fullLabel: String {
        switch true {
        case tracks.isEmpty: return "無軌"
        case allDone: return "已釘選（\(tracks.count) 軌，點擊取消）"
        case done + pending > 0:
            return "釘選中 \(done)/\(tracks.count)" + (failed > 0 ? " · \(failed) 失敗" : "")
        case failed > 0: return "釘選失敗 \(failed)/\(tracks.count)（點擊重試）"
        default: return "釘選離線（\(tracks.count) 軌）"
        }
    }

    private var shortLabel: String {
        if allDone { return "已釘選" }
        if pending > 0 { return "\(done)/\(tracks.count)" }
        if failed > 0 { return "重試" }
        return "釘選離線"
    }

    var body: some View {
        Button {
            allDone ? unpin() : pin()
        } label: {
            HStack(spacing: 4) {
                if pending > 0 {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: allDone ? "checkmark.circle.fill"
                          : failed > 0 ? "exclamationmark.arrow.circlepath" : "arrow.down.circle")
                }
                Text(shortLabel)
            }
        }
        .buttonStyle(.bordered)
        .disabled(tracks.isEmpty)
        .help(fullLabel)
        .accessibilityLabel(fullLabel)
        .accessibilityIdentifier("pinChip")
    }
}

// MARK: - 播放列

/// hasQueue gate 需在訂閱 player 的視圖內（同 MuiOS 教訓）。
private struct MacPlayerBarHost: View {
    @ObservedObject var player: MacPlayer

    var body: some View {
        if player.hasQueue {
            MacPlayerBar(player: player)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct MacPlayerBar: View {
    @ObservedObject var player: MacPlayer
    @EnvironmentObject private var model: MacModel

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                ArtworkImage(key: player.nowTrack?.albumId ?? "",
                             url: player.nowTrack.map { model.artworkURL(for: $0.albumId) } ?? nil,
                             loader: model.artwork, cornerRadius: 6)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(player.nowTitle ?? "")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                        .accessibilityIdentifier("player.title")
                    Text(player.nowArtist ?? "")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                transport("backward.fill", size: 13) { player.previous() }
                transport(player.isPlaying ? "pause.fill" : "play.fill", size: 20) { player.toggle() }
                    .accessibilityIdentifier("player.toggle")
                transport("forward.fill", size: 13) { player.next() }
                    .accessibilityIdentifier("player.next")
            }
            MacProgressBar(elapsed: player.elapsed, duration: player.duration) { player.seek(to: $0) }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func transport(_ symbol: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 細進度條：顯示進度 + 點擊/拖曳跳轉；兩端時間。
private struct MacProgressBar: View {
    let elapsed: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @State private var dragFrac: Double?

    var body: some View {
        HStack(spacing: 8) {
            Text(fmtClock(shown))
            GeometryReader { g in
                let frac = duration > 0 ? min(1, shown / duration) : 0
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule().fill(Color.accentColor).frame(width: g.size.width * frac)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            dragFrac = min(1, max(0, v.location.x / g.size.width))
                        }
                        .onEnded { v in
                            let f = min(1, max(0, v.location.x / g.size.width))
                            dragFrac = nil
                            onSeek(f * duration)
                        }
                )
            }
            .frame(height: 14)
            Text("-" + fmtClock(max(0, duration - shown)))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var shown: Double { dragFrac.map { $0 * duration } ?? elapsed }
}

// MARK: - 格式化

private func fmtDuration(_ ms: Int?) -> String {
    guard let ms, ms >= 0 else { return "" }
    return String(format: "%d:%02d", ms / 60000, ms / 1000 % 60)
}

private func fmtClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

private func fmtTotal(_ tracks: [Track]) -> String {
    let secs = tracks.compactMap(\.durationMs).reduce(0, +) / 1000
    if secs >= 3600 { return "\(secs / 3600) 小時 \(secs / 60 % 60) 分鐘" }
    return "\(max(1, secs / 60)) 分鐘"
}
