import SwiftUI
import MuCore
import MuKit

/// 設計常數：圓角/間距單一來源，各頁面不各自硬編。
enum MuTheme {
    static let radiusS: CGFloat = 8
    static let radiusM: CGFloat = 14
    static let radiusL: CGFloat = 22
    static let pageInset: CGFloat = 20
    static let gridSpacing: CGFloat = 14
}

/// 音軌列（專輯/清單共用）：序號或播放中喇叭、標題（+副標）、離線標記、時長。
/// accessibility：整列 `track.<index>`，離線圖示 label「離線」。
struct TrackRow: View {
    let index: Int
    let number: Int?
    let title: String
    var subtitle: String? = nil
    let durationMs: Int?
    let isPlaying: Bool
    let isOffline: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    if isPlaying {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    } else {
                        Text(number.map(String.init) ?? "")
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 26, alignment: .center)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                        .foregroundStyle(isPlaying ? Color.accentColor : Color.primary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isOffline {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("離線")
                }
                Text(fmtDuration(durationMs))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            .padding(.horizontal, MuTheme.pageInset)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("track.\(index)")
    }
}

/// 音軌清單 + 列間分隔線（縮排對齊標題）。
struct TrackList<Row: View>: View {
    let count: Int
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                row(i)
                if i < count - 1 {
                    Divider().padding(.leading, MuTheme.pageInset + 38)
                }
            }
        }
    }
}

/// 詳情頁頁尾統計（「12 首歌曲 · 48 分鐘」）。
struct TrackSummary: View {
    let tracks: [Track]

    var body: some View {
        Text("\(tracks.count) 首歌曲 · \(fmtTotal(tracks))")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MuTheme.pageInset)
            .padding(.vertical, 16)
    }
}

/// 區段標題（「專輯」+ 計數）。
struct SectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.title2.weight(.bold))
            Text("\(count)").font(.subheadline).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, MuTheme.pageInset)
    }
}

/// 釘選按鈕：視覺短標籤 + 圖示；accessibility label 為完整狀態句（UI 測試依賴）。
struct PinButton: View {
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
        case tracks.isEmpty:
            return "無軌"
        case allDone:
            return "已釘選（\(tracks.count) 軌，點擊取消）"
        case done + pending > 0:
            return "釘選中 \(done)/\(tracks.count)" + (failed > 0 ? " · \(failed) 失敗" : "")
        case failed > 0:
            return "釘選失敗 \(failed)/\(tracks.count)（點擊重試）"
        default:
            return "釘選離線（\(tracks.count) 軌）"
        }
    }

    var body: some View {
        Button {
            allDone ? unpin() : pin()
        } label: {
            HStack(spacing: 6) {
                if pending > 0 {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: icon)
                }
                Text(shortLabel)
            }
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity)
        }
        .tint(failed > 0 && pending == 0 ? .orange : .accentColor)
        .disabled(tracks.isEmpty)
        .accessibilityLabel(fullLabel)
        .accessibilityIdentifier("pinChip")
    }

    private var icon: String {
        if allDone { return "checkmark.circle.fill" }
        if failed > 0 { return "exclamationmark.arrow.circlepath" }
        return "arrow.down.circle"
    }

    private var shortLabel: String {
        if tracks.isEmpty { return "無軌" }
        if allDone { return "已釘選" }
        if pending > 0 { return "釘選中 \(done)/\(tracks.count)" }
        if failed > 0 { return "重試釘選" }
        return "釘選離線"
    }
}

/// 詳情頁「播放」主按鈕。
struct PlayAllButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("播放", systemImage: "play.fill")
                .font(.body.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }
}

func fmtDuration(_ ms: Int?) -> String {
    guard let ms, ms >= 0 else { return "" }
    return String(format: "%d:%02d", ms / 60000, ms / 1000 % 60)
}

func fmtClock(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.rounded()))
    return s >= 3600
        ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
        : String(format: "%d:%02d", s / 60, s % 60)
}

func fmtTotal(_ tracks: [Track]) -> String {
    let secs = tracks.compactMap(\.durationMs).reduce(0, +) / 1000
    if secs >= 3600 { return "\(secs / 3600) 小時 \(secs / 60 % 60) 分鐘" }
    return "\(max(1, secs / 60)) 分鐘"
}
