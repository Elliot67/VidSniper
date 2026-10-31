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

    /// Mix pour l'export, sans traitement audio : AVFoundation plante au démarrage de la lecture quand des
    /// `MTAudioProcessingTap` sont combinés à une composition vidéo Core Image. Les volumes sont ramenés sous
    /// 100 % (seul cas géré par `setVolume`) en les divisant par le plus fort ; ce gain global est rendu
    /// ensuite sur le son mixé (`masterGain`). Le résultat est le même, le mix étant linéaire.
    static func forExport(_ volumes: [AudioTrackVolume]) -> (mix: AVAudioMix, masterGain: Float) {
        let masterGain = max(1, volumes.map(\.volume).max() ?? 1)
        let mix = AVMutableAudioMix()
        mix.inputParameters = volumes.map { volume in
            let parameters = AVMutableAudioMixInputParameters()
            parameters.trackID = volume.trackID
            parameters.setVolume(volume.volume / masterGain, at: .zero)
            return parameters
        }
        return (mix, masterGain)
    }
}

/// Multiplie les échantillons Float32 d'un tampon audio (écrêtés à ±1), en place.
func applyGain(_ gain: Float, to sampleBuffer: CMSampleBuffer) {
    guard gain != 1, let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
    let totalLength = CMBlockBufferGetDataLength(block)
    var offset = 0
    // Un tampon peut être fait de plusieurs morceaux non contigus.
    while offset < totalLength {
        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            block, atOffset: offset, lengthAtOffsetOut: &length, totalLengthOut: nil, dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr, let pointer, length > 0 else { return }
        let count = length / MemoryLayout<Float>.size
        pointer.withMemoryRebound(to: Float.self, capacity: count) { samples in
            for index in 0..<count {
                samples[index] = min(1, max(-1, samples[index] * gain))
            }
        }
        offset += length
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
