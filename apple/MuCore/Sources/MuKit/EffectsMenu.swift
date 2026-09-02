#if canImport(SwiftUI)
import MuCore
import SwiftUI

/// 音效選單內容（ReplayGain 模式 + EQ preset/前置增益）：iOS 現正播放與 macOS 更多選單共用。
/// 呼叫端各自決定外層容器（Menu／Picker 的 label、分區），這裡只提供選項本身。
public struct EffectsMenuContent: View {
    @Binding public var replayGainMode: ReplayGain.Mode
    @Binding public var eq: EqSettings

    public init(replayGainMode: Binding<ReplayGain.Mode>, eq: Binding<EqSettings>) {
        _replayGainMode = replayGainMode
        _eq = eq
    }

    public var body: some View {
        Picker("音量標準化", selection: $replayGainMode) {
            ForEach(ReplayGain.Mode.allCases, id: \.self) { m in
                Text(m.label).tag(m)
            }
        }
        .pickerStyle(.menu)

        Picker("等化器", selection: presetBinding) {
            Text("關閉").tag("")
            ForEach(EqSettings.presets, id: \.name) { p in
                Text(DisplayFormat.eqPresetLabel(p.name)).tag(p.name)
            }
        }
        .pickerStyle(.menu)

        Picker("前置增益", selection: preampBinding) {
            ForEach(DisplayFormat.eqPreampChoicesMb, id: \.self) { mb in
                Text(DisplayFormat.gainLabel(mb: mb)).tag(mb)
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
#endif
