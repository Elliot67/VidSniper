import AVFoundation

enum ExportError: LocalizedError {
    case cannotRead(Error?)
    case cannotWrite(Error?)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let error): error?.localizedDescription ?? "Lecture du montage impossible."
        case .cannotWrite(let error): error?.localizedDescription ?? "Écriture du MP4 impossible."
        }
    }
}

/// Encode un montage en MP4 H.264 + AAC avec un débit maîtrisé (AVAssetReader → AVAssetWriter) :
/// redimensionnement, 30 i/s, et les pistes audio gardées mixées en une seule piste stéréo.
enum VideoExporter {
    static func export(
        _ composition: AVComposition,
        plan: ExportPlan,
        volumes: [AudioTrackVolume],
        clicks: ClickOverlay?,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let job = try await ExportJob(composition: composition, plan: plan, volumes: volumes, clicks: clicks, url: url)
        try await withTaskCancellationHandler {
            try await job.run(duration: plan.duration, progress: progress)
        } onCancel: {
            job.cancel()
        }
    }
}

/// Les objets AVFoundation d'un export. Ils ne sont manipulés que par leurs files de travail.
private final class ExportJob: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let videoOutput: AVAssetReaderVideoCompositionOutput
    private let videoInput: AVAssetWriterInput
    private let audioOutput: AVAssetReaderAudioMixOutput?
    private let audioInput: AVAssetWriterInput?
    /// Gain appliqué au son mixé (voir `AVAudioMix.forExport`).
    private let audioMasterGain: Float

    init(
        composition: AVComposition,
        plan: ExportPlan,
        volumes: [AudioTrackVolume],
        clicks: ClickOverlay?,
        url: URL
    ) async throws {
        do {
            reader = try AVAssetReader(asset: composition)
        } catch {
            throw ExportError.cannotRead(error)
        }
        let videoTracks = try await composition.loadTracks(withMediaType: .video)
        let audioTracks = try await composition.loadTracks(withMediaType: .audio)
        let renderSize = CGSize(width: plan.width, height: plan.height)

        // Composition vidéo à 30 i/s (l'enregistrement est à 60 i/s, variable), rendue directement à la taille
        // d'export : à 75 % ou 50 %, il y a beaucoup moins de pixels à composer puis à encoder.
        // Avec des clics à dessiner, on passe par Core Image ; sinon, le chemin direct (plus rapide).
        let videoComposition: AVMutableVideoComposition
        if let clicks {
            videoComposition = try await VideoEffects.videoComposition(
                for: UncheckedSendable(composition),
                clicks: clicks,
                renderSize: renderSize,
                frameRate: ExportPlan.frameRate
            )
        } else {
            videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
            videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(ExportPlan.frameRate))
        }
        if clicks == nil, let track = videoTracks.first {
            let naturalSize = videoComposition.renderSize
            if naturalSize.width > 0, naturalSize.height > 0, naturalSize != renderSize {
                let transform = try await track.load(.preferredTransform)
                    .concatenating(CGAffineTransform(
                        scaleX: renderSize.width / naturalSize.width,
                        y: renderSize.height / naturalSize.height
                    ))
                let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
                layer.setTransform(transform, at: .zero)
                let instruction = AVMutableVideoCompositionInstruction()
                instruction.timeRange = CMTimeRange(start: .zero, duration: try await composition.load(.duration))
                instruction.layerInstructions = [layer]
                videoComposition.instructions = [instruction]
                videoComposition.renderSize = renderSize
            }
        }

        videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOutput.videoComposition = videoComposition
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        if plan.hasAudio, !audioTracks.isEmpty {
            // Float32 : le gain global se calcule directement sur les échantillons mixés.
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ])
            let (mix, masterGain) = AVAudioMix.forExport(volumes)
            // Les échantillons sont modifiés sur place : il faut une copie à nous.
            output.alwaysCopiesSampleData = masterGain != 1
            output.audioMix = mix
            reader.add(output)
            audioOutput = output
            audioMasterGain = masterGain
        } else {
            audioOutput = nil
            audioMasterGain = 1
        }

        do {
            writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        } catch {
            throw ExportError.cannotWrite(error)
        }
        writer.shouldOptimizeForNetworkUse = true

        // Les images arrivent déjà à la bonne taille (le mode de mise à l'échelle n'est qu'une sécurité).
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: plan.width,
            AVVideoHeightKey: plan.height,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoBitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: ExportPlan.frameRate,
                AVVideoMaxKeyFrameIntervalKey: Int(ExportPlan.frameRate * 2),
                // Sans images B : encodage plus rapide, pour un fichier à peine plus lourd.
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        writer.add(videoInput)

        if audioOutput != nil {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: ExportPlan.audioBitrate,
                AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            audioInput = input
        } else {
            audioInput = nil
        }
    }

    func run(duration: Double, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard reader.startReading() else { throw ExportError.cannotRead(reader.error) }
        guard writer.startWriting() else { throw ExportError.cannotWrite(writer.error) }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var lastReported = -1.0
                await self.pump(self.videoOutput, into: self.videoInput, label: "video") { sampleBuffer in
                    let time = sampleBuffer.presentationTimeStamp
                    let value = duration > 0 ? min(1, time.seconds / duration) : 0
                    if value - lastReported >= 0.01 {
                        lastReported = value
                        progress(value)
                    }
                }
            }
            if let audioOutput, let audioInput {
                let gain = audioMasterGain
                group.addTask {
                    await self.pump(audioOutput, into: audioInput, label: "audio") { sampleBuffer in
                        applyGain(gain, to: sampleBuffer)
                    }
                }
            }
        }

        try Task.checkCancellation()
        if reader.status == .failed {
            writer.cancelWriting()
            throw ExportError.cannotRead(reader.error)
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.cannotWrite(writer.error) }
        progress(1)
    }

    func cancel() {
        reader.cancelReading()
        writer.cancelWriting()
    }

    /// Recopie les échantillons de la sortie du lecteur vers l'entrée du writer, au rythme du writer.
    /// `onSample` voit (et peut modifier) chaque tampon avant son écriture.
    private func pump(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        label: String,
        onSample: ((CMSampleBuffer) -> Void)?
    ) async {
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        nonisolated(unsafe) let onSample = onSample
        nonisolated(unsafe) let reader = reader
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "VidSniper.export.\(label)")) {
                while input.isReadyForMoreMediaData {
                    guard reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onSample?(sampleBuffer)
                    if !input.append(sampleBuffer) {
                        reader.cancelReading()
                    }
                }
            }
        }
    }
}
