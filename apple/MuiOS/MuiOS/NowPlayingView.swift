import SwiftUI
import MuCore
import MuKit

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
    /// 有封面 → 封面平均色；灰階封面 → 不染色（亂染比不染難看）。
    private enum Ambient: Equatable {
        case albumHue, plain, artwork(Color)
    }

    private var track: Track? { player.nowTrack }
    private var albumKey: String { track?.albumId ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)

            ArtworkImage(key: albumKey,
                         url: track.map { model.artworkURL(for: $0.albumId) } ?? nil,
                         loader: model.artwork,
                         cornerRadius: MuTheme.radiusL)
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
                    Picker("音量標準化", selection: $player.replayGainMode) {
                        ForEach(ReplayGain.Mode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    EqMenuContent(eq: $player.eq)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: MuTheme.hitTarget, height: MuTheme.hitTarget)
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
                    Text(fmtClock(scrubbing ? scrubValue : player.elapsed))
                    Spacer()
                    Text("-" + fmtClock(upper - (scrubbing ? scrubValue : player.elapsed)))
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
                .frame(width: MuTheme.hitTarget, height: MuTheme.hitTarget)
                .padding(.top, 16)
                .padding(.bottom, 4)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(AmbientBackground(tint: ambientTint))
        .animation(.easeOut(duration: 0.35), value: ambientTint)
        .presentationDragIndicator(.visible)
        .task(id: albumKey) {
            ambient = .albumHue
            guard let track, let url = model.artworkURL(for: track.albumId),
                  let image = await model.artwork.image(key: albumKey, trackURL: url) else {
                return  // 沒有封面 → 維持專輯色相（與佔位圖同色）
            }
            ambient = ArtworkTint.hueSaturation(from: image).map {
                .artwork(Color(hue: $0.hue,
                               saturation: min(0.6, max(0.35, $0.saturation)),
                               brightness: 0.6))
            } ?? .plain
        }
    }

    private var ambientTint: Color? {
        switch ambient {
        case .albumHue:
            return Color(hue: PlaceholderArt.hue(for: albumKey), saturation: 0.55, brightness: 0.6)
        case .plain:
            return nil
        case .artwork(let color):
            return color
        }
    }

    private var effectsLabel: String {
        player.eq.enabled
            ? "音效：等化器 \(EqLabels.presetLabel(player.eq.preset))"
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

/// EQ 選單（preset / 前置增益 / 關閉）——iOS 與 MuMac 共用文案（EqLabels）。
struct EqMenuContent: View {
    @Binding var eq: EqSettings

    var body: some View {
        Picker("等化器", selection: presetBinding) {
            Text("關閉").tag("")
            ForEach(EqSettings.presets, id: \.name) { p in
                Text(EqLabels.presetLabel(p.name)).tag(p.name)
            }
        }
        .pickerStyle(.menu)
        Picker("前置增益", selection: preampBinding) {
            ForEach(EqLabels.preampChoices, id: \.self) { mb in
                Text(EqLabels.preampLabel(mb)).tag(mb)
            }
        }
        .pickerStyle(.menu)
        .disabled(!eq.enabled)
    }

    private var presetBinding: Binding<String> {
        Binding(get: { eq.enabled ? eq.preset : "" },
                set: { name in
                    eq = name.isEmpty
                        ? EqSettings(bands: eq.bands, enabled: false, preamp: eq.preamp, preset: eq.preset)
                        : EqSettings.preset(name, enabled: true, preamp: eq.preamp)
                })
    }

    private var preampBinding: Binding<Int> {
        Binding(get: { eq.preamp },
                set: { eq = EqSettings(bands: eq.bands, enabled: eq.enabled, preamp: $0, preset: eq.preset) })
    }
}

enum EqLabels {
    static let preampChoices = [-600, -300, 0, 300, 600]

    static func preampLabel(_ mb: Int) -> String {
        mb == 0 ? "0 dB" : String(format: "%+.0f dB", Double(mb) / 100)
    }

    static func presetLabel(_ name: String) -> String {
        switch name {
        case "flat": return "平坦"
        case "rock": return "搖滾"
        case "pop": return "流行"
        case "jazz": return "爵士"
        case "classical": return "古典"
        case "bass": return "重低音"
        case "treble": return "高音"
        case "vocal": return "人聲"
        case "loudness": return "響度"
        default: return name
        }
    }
}
