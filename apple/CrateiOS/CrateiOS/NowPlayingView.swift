import SwiftUI
import CrateCore
import CrateKit

/// 現正播放（全頁 sheet）：大封面（暫停時縮小）、標題/藝人、可拖曳進度條、
/// 上一首/播放/下一首、音效選單與 AirPlay。
/// 背景是封面的氛圍色：從上緣往下收乾淨，文字與控制區維持系統底色（對比不受影響）。
struct NowPlayingView: View {
    @ObservedObject var player: PlayerManager
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var ambient: Ambient = .albumHue

    /// 頂部氛圍色的來源：尚未判定/無封面 → 專輯 id 的穩定色相（同佔位圖）；
    /// 有封面 → 封面色相；灰階封面 → 不染色（亂染比不染難看）。
    fileprivate enum Ambient: Equatable {
        case albumHue, plain, artwork(hue: Double)
    }

    private var track: Track? { player.nowTrack }
    private var albumKey: String { track?.albumId ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            ArtworkImage(key: albumKey,
                         url: track.map { model.artworkURL(for: $0.albumId) } ?? nil,
                         loader: model.artwork,
                         cornerRadius: CrateTheme.radiusL)
                .shadow(color: .black.opacity(0.22), radius: 20, y: 10)
                .scaleEffect(reduceMotion || player.isPlaying ? 1 : 0.88)
                .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8),
                           value: player.isPlaying)
                .padding(.horizontal, 2)
                .accessibilityHidden(true)

            Spacer(minLength: 24)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(player.nowTitle ?? "")
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .accessibilityIdentifier("nowPlaying.title")
                    Text(player.nowArtist ?? "")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Menu {
                    EffectsMenuContent(replayGainMode: $player.replayGainMode, eq: $player.eq)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: CrateTheme.hitTarget, height: CrateTheme.hitTarget)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel(effectsLabel)
                .accessibilityIdentifier("nowPlaying.replayGain")
            }

            VStack(spacing: 2) {
                Slider(value: progress, in: 0...upper, onEditingChanged: editingChanged)
                    .tint(.primary)
                    .accessibilityLabel("播放進度")
                HStack {
                    Text(DisplayFormat.clock(seconds: scrubbing ? scrubValue : player.elapsed))
                    Spacer()
                    Text("-" + DisplayFormat.clock(seconds: upper - (scrubbing ? scrubValue : player.elapsed)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.top, 16)

            HStack(spacing: 0) {
                transport("backward.fill", size: 28, label: "上一首", id: "nowPlaying.previous") {
                    player.previous()
                }
                Spacer()
                transport(player.isPlaying ? "pause.fill" : "play.fill", size: 44,
                          label: player.isPlaying ? "暫停" : "播放", id: "nowPlaying.toggle") {
                    player.toggle()
                }
                Spacer()
                transport("forward.fill", size: 28, label: "下一首", id: "nowPlaying.next") {
                    player.next()
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 12)

            RoutePicker()
                .frame(width: CrateTheme.hitTarget, height: CrateTheme.hitTarget)
                .padding(.top, 16)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(AmbientBackground(tint: ambientTint))
        .animation(.easeOut(duration: 0.35), value: ambientTint)
        .presentationDragIndicator(.visible)
        .task(id: albumKey) {
            if let cached = AmbientCache.shared.value(for: albumKey) {
                ambient = cached
                return
            }
            ambient = .albumHue
            guard let track, let url = model.artworkURL(for: track.albumId),
                  let image = await model.artwork.image(key: albumKey, trackURL: url) else {
                return  // 沒有封面 → 維持專輯色相（與佔位圖同色）
            }
            // 平均色萃取是純函式；丟到背景執行緒算，算完才跳回來設狀態。
            let resolved = await Task.detached(priority: .utility) {
                ArtworkTint.hue(from: image).map { Ambient.artwork(hue: $0) } ?? .plain
            }.value
            AmbientCache.shared.set(resolved, for: albumKey)
            ambient = resolved
        }
    }

    /// 封面色與專輯色相都是同一套飽和度/亮度，只有色相來源不同——維持一致的染色強度。
    private var ambientTint: Color? {
        switch ambient {
        case .albumHue:
            return Color(hue: PlaceholderArt.hue(for: albumKey), saturation: 0.55, brightness: 0.6)
        case .plain:
            return nil
        case .artwork(let hue):
            return Color(hue: hue, saturation: 0.55, brightness: 0.6)
        }
    }

    private var effectsLabel: String {
        player.eq.enabled
            ? "音效：等化器 \(DisplayFormat.eqPresetLabel(player.eq.preset))"
            : "音效：ReplayGain \(player.replayGainMode.label)"
    }

    private var upper: Double { max(player.duration, 1) }

    private var progress: Binding<Double> {
        Binding(get: { scrubbing ? scrubValue : min(player.elapsed, upper) },
                set: { scrubValue = $0 })
    }

    private func editingChanged(_ editing: Bool) {
        if editing {
            scrubValue = player.elapsed
            scrubbing = true
        } else {
            player.seek(to: scrubValue)
            scrubbing = false
        }
    }

    private func transport(_ symbol: String, size: CGFloat, label: String, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

/// 現正播放背景：系統底色 + 頂部氛圍色漸層（下半部收乾淨，不影響文字對比）。
private struct AmbientBackground: View {
    let tint: Color?

    var body: some View {
        ZStack {
            Color(.systemBackground)
            if let tint {
                LinearGradient(colors: [tint.opacity(0.34), tint.opacity(0.10), .clear],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .ignoresSafeArea()
    }
}

/// 封面氛圍色快取（純函式的結果，跨次開啟現正播放不必重算）：albumId → 判定結果。
private final class AmbientCache {
    static let shared = AmbientCache()
    private let lock = NSLock()
    private var storage: [String: NowPlayingView.Ambient] = [:]

    func value(for key: String) -> NowPlayingView.Ambient? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ value: NowPlayingView.Ambient, for key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }
}
