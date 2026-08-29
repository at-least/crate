import AVFoundation
import Foundation
import MediaToolbox
import MuCore

/// AVPlayer 音訊處理節點（MTAudioProcessingTap）：把 MuCore.AudioDsp 掛進 AVQueuePlayer 的播放路徑。
/// 選擇 tap 而非改寫成 AVAudioEngine 的理由：保留 AVQueuePlayer 的佇列/接力（gapless）與既有播放行為，
/// 只在音訊資料流上加一段處理（model.md §1.10）。
///
/// 生命週期：每個 AVPlayerItem 一個 tap（各自的 prepare/unprepare），共用同一個 `AudioDsp`
/// （同時只有一個 item 在發聲；prepare 時 reset 濾波器狀態）。
public final class AudioTapAttacher {

    /// tap 的 C 回呼透過此 box 取得 DSP（Unmanaged 存於 tap storage）。
    final class Box {
        let dsp: AudioDsp
        init(dsp: AudioDsp) { self.dsp = dsp }
    }

    public let dsp: AudioDsp

    public init(dsp: AudioDsp = AudioDsp()) {
        self.dsp = dsp
    }

    /// 為 item 掛上 audioMix（找不到音訊軌 → 不掛，播放照常）。
    /// 非同步載入軌道；完成後在主佇列指派（AVPlayerItem.audioMix 可於播放中設定）。
    public func attach(to item: AVPlayerItem) {
        let asset = item.asset
        Task { [weak item] in
            let tracks = try? await asset.loadTracks(withMediaType: .audio)
            guard let track = tracks?.first, let item else { return }
            guard let mix = self.makeAudioMix(for: track) else { return }
            await MainActor.run { item.audioMix = mix }
        }
    }

    func makeAudioMix(for track: AVAssetTrack) -> AVAudioMix? {
        let boxPtr = Unmanaged.passRetained(Box(dsp: dsp)).toOpaque()
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: boxPtr,
            init: tapInit,
            finalize: tapFinalize,
            prepare: tapPrepare,
            unprepare: tapUnprepare,
            process: tapProcess)

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks,
            kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            Unmanaged<Box>.fromOpaque(boxPtr).release() // tapInit 不會被呼叫 → 自行交還 +1
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap // ARC 管理；params 持有 tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

// MARK: - C 回呼（音訊執行緒；不配置記憶體、不做阻塞 IO）

private let tapInit: MTAudioProcessingTapInitCallback = { _, clientInfo, tapStorageOut in
    tapStorageOut.pointee = clientInfo // Box 的 +1 由 clientInfo 轉交 storage
}

private let tapFinalize: MTAudioProcessingTapFinalizeCallback = { tap in
    Unmanaged<AudioTapAttacher.Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
}

private let tapPrepare: MTAudioProcessingTapPrepareCallback = { tap, _, format in
    let box = Unmanaged<AudioTapAttacher.Box>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    let asbd = format.pointee
    box.dsp.prepare(sampleRate: asbd.mSampleRate, channels: Int(asbd.mChannelsPerFrame))
    box.dsp.reset()
}

private let tapUnprepare: MTAudioProcessingTapUnprepareCallback = { tap in
    Unmanaged<AudioTapAttacher.Box>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().dsp.reset()
}

private let tapProcess: MTAudioProcessingTapProcessCallback = {
    tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
    let status = MTAudioProcessingTapGetSourceAudio(
        tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
    guard status == noErr else { return }
    let box = Unmanaged<AudioTapAttacher.Box>
        .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
    guard !box.dsp.isIdentity else { return }

    let abl = UnsafeMutableAudioBufferListPointer(bufferListInOut)
    let frames = Int(numberFramesOut.pointee)
    guard frames > 0, abl.count > 0 else { return }

    if abl.count > 1 { // 非交錯：每個 buffer 一個聲道
        var planes: [UnsafeMutablePointer<Float>] = []
        planes.reserveCapacity(abl.count)
        for buffer in abl {
            guard let data = buffer.mData else { return }
            planes.append(data.assumingMemoryBound(to: Float.self))
        }
        box.dsp.process(planar: planes, frames: frames)
    } else {
        guard let data = abl[0].mData else { return }
        let channels = Int(abl[0].mNumberChannels)
        box.dsp.process(data.assumingMemoryBound(to: Float.self),
                        frames: frames, channels: max(channels, 1))
    }
}
