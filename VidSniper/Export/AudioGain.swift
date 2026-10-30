import AVFoundation
import MediaToolbox

/// Gain d'une piste audio, lu en continu par le traitement audio. Le modifier change le volume
/// immédiatement, sans reconstruire le mix (pratique pour un curseur pendant la lecture).
final class AudioGain: @unchecked Sendable {
    var value: Float
    /// Le traitement ne sait multiplier que des échantillons Float32 (format habituel du mixeur).
    fileprivate var isFloat32 = false

    init(_ value: Float) {
        self.value = value
    }
}

extension AVAudioMix {
    /// Mix où chaque piste passe par un traitement de gain : contrairement à `setVolume`,
    /// limité à 100 %, il permet d'amplifier (avec écrêtage pour éviter la saturation numérique).
    static func with(gains: [(trackID: CMPersistentTrackID, gain: AudioGain)]) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = gains.map { track in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = track.trackID
            parameters.audioTapProcessor = makeGainTap(track.gain)
            return parameters
        }
        return mix
    }

    /// Mix figé pour l'export.
    static func with(_ volumes: [AudioTrackVolume]) -> AVAudioMix {
        with(gains: volumes.map { ($0.trackID, AudioGain($0.volume)) })
    }
}

private func makeGainTap(_ gain: AudioGain) -> MTAudioProcessingTap? {
    var callbacks = MTAudioProcessingTapCallbacks(
        version: kMTAudioProcessingTapCallbacksVersion_0,
        // Chaque tap garde une référence sur le gain, rendue dans `finalize`.
        clientInfo: Unmanaged.passRetained(gain).toOpaque(),
        init: { _, clientInfo, storage in
            storage.pointee = clientInfo
        },
        finalize: { tap in
            Unmanaged<AudioGain>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
        },
        prepare: { tap, _, format in
            let gain = Unmanaged<AudioGain>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            let description = format.pointee
            gain.isFloat32 = description.mFormatFlags & kAudioFormatFlagIsFloat != 0 && description.mBitsPerChannel == 32
        },
        unprepare: nil,
        process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
            guard MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, flagsOut, nil, frameCountOut) == noErr
            else { return }
            let gain = Unmanaged<AudioGain>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            let factor = gain.value
            guard gain.isFloat32, factor != 1 else { return }
            for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                guard let data = buffer.mData else { continue }
                let samples = data.assumingMemoryBound(to: Float.self)
                for index in 0..<Int(buffer.mDataByteSize) / MemoryLayout<Float>.size {
                    samples[index] = min(1, max(-1, samples[index] * factor))
                }
            }
        }
    )

    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
    if status != noErr {
        Unmanaged.passUnretained(gain).release()
        return nil
    }
    return tap
}
