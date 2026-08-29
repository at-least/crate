import SwiftUI
import MuCore
import MuKit

/// 現正播放（全頁 sheet）：大封面（播放時放大）、標題/藝人/專輯、可拖曳進度條、
/// 上一首/播放/下一首、AirPlay 路由。背景以專輯佔位色淡淡染色，每張專輯氛圍不同。
struct NowPlayingView: View {
    @ObservedObject var player: PlayerManager
    @EnvironmentObject private var model: AppModel
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    private var track: Track? { player.nowTrack }
    private var albumKey: String { track?.albumId ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 12)

            ArtworkImage(key: albumKey,
                         url: track.map { model.artworkURL(for: $0.albumId) } ?? nil,
                         loader: model.artwork,
                         cornerRadius: MuTheme.radiusL)
                .shadow(color: .black.opacity(0.28), radius: 28, y: 14)
                .scaleEffect(player.isPlaying ? 1 : 0.86)
                .animation(.spring(response: 0.45, dampingFraction: 0.8), value: player.isPlaying)
                .padding(.horizontal, 32)

            Spacer(minLength: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(player.nowTitle ?? "")
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                    .accessibilityIdentifier("nowPlaying.title")
                Text(player.nowArtist ?? "")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let album = track?.album, !album.isEmpty {
                    Text(album)
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 4) {
                Slider(value: progress, in: 0...upper, onEditingChanged: editingChanged)
                .tint(.primary)
                HStack {
                    Text(fmtClock(scrubbing ? scrubValue : player.elapsed))
                    Spacer()
                    Text("-" + fmtClock(upper - (scrubbing ? scrubValue : player.elapsed)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .padding(.top, 20)

            HStack(spacing: 0) {
                transport("backward.fill", size: 30, id: "nowPlaying.previous") { player.previous() }
                Spacer()
                transport(player.isPlaying ? "pause.fill" : "play.fill", size: 48,
                          id: "nowPlaying.toggle") { player.toggle() }
                Spacer()
                transport("forward.fill", size: 30, id: "nowPlaying.next") { player.next() }
            }
            .padding(.horizontal, 36)
            .padding(.top, 16)

            HStack(spacing: 24) {
                Menu {
                    Picker("ReplayGain", selection: $player.replayGainMode) {
                        ForEach(ReplayGain.Mode.allCases, id: \.self) { m in
                            Text(m.label).tag(m)
                        }
                    }
                    Divider()
                    EqMenuContent(eq: $player.eq)
                } label: {
                    Label(player.eq.enabled
                          ? "音效：\(EqLabels.presetLabel(player.eq.preset))"
                          : "ReplayGain：\(player.replayGainMode.label)",
                          systemImage: "waveform.badge.minus")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("nowPlaying.replayGain")
                RoutePicker()
                    .frame(width: 44, height: 44)
            }
            .padding(.top, 20)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 20)
        .background(
            PlaceholderArt(key: albumKey, symbol: "")
                .opacity(0.22)
                .overlay(Color(.systemBackground).opacity(0.35))
                .ignoresSafeArea()
        )
        .presentationDragIndicator(.visible)
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

    private func transport(_ symbol: String, size: CGFloat, id: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .frame(width: 64, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
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
        Picker("前置增益", selection: preampBinding) {
            ForEach(EqLabels.preampChoices, id: \.self) { mb in
                Text(EqLabels.preampLabel(mb)).tag(mb)
            }
        }
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
