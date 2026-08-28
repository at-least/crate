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

            RoutePicker()
                .frame(width: 44, height: 44)
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
