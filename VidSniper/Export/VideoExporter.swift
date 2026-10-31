import AVFoundation

enum ExportError: LocalizedError {
    case cannotRead(Error?)
    case cannotWrite(Error?)

    var errorDescription: String? {
        switch self {
        case .cannotRead(let error): error?.localizedDescription ?? String(localized: "Couldn't read the edit.")
        case .cannotWrite(let error): error?.localizedDescription ?? String(localized: "Couldn't write the MP4.")
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
        annotations: AnnotationOverlay?,
        to url: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: url)
        let job = try await ExportJob(
            composition: composition, plan: plan, volumes: volumes, clicks: clicks, annotations: annotations, url: url
        )
        try await withTaskCancellationHandler {
            try await job.run(duration: plan.duration, progress: progress)
        } onCancel: {
            job.cancel()
        }
    }
}

/// Les objets AVFoundation d'un export. Après la configuration, le lecteur et le writer ne sont
/// manipulés que sur `queue` (démarrage, lecture des échantillons, annulation).
private final class ExportJob: @unchecked Sendable {
    private let queue = DispatchQueue(label: "VidSniper.export")
    /// Sur `queue` uniquement.
    private var isCancelled = false
    /// Pompes en cours (vidéo, audio), à reprendre en cas d'annulation. Sur `queue` uniquement.
    private var pendingPumps: [Int: CheckedContinuation<Void, Never>] = [:]

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
        annotations: AnnotationOverlay?,
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
        // Avec des clics ou des annotations à dessiner, on passe par Core Image ; sinon, le chemin direct (plus rapide).
        let usesEffects = clicks != nil || annotations != nil
        let videoComposition: AVMutableVideoComposition
        if usesEffects {
            videoComposition = try await VideoEffects.videoComposition(
                for: UncheckedSendable(composition),
                clicks: clicks,
                annotations: annotations,
                renderSize: renderSize,
                frameRate: ExportPlan.frameRate
            )
        } else {
            videoComposition = try await AVMutableVideoComposition.videoComposition(withPropertiesOf: composition)
            videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(ExportPlan.frameRate))
        }
        if !usesEffects, let track = videoTracks.first {
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
        // Démarrage sur la file de travail : une annulation ne peut pas tomber au milieu.
        try queue.sync {
            guard !isCancelled else { throw CancellationError() }
            guard reader.startReading() else { throw ExportError.cannotRead(reader.error) }
            guard writer.startWriting() else { throw ExportError.cannotWrite(writer.error) }
            writer.startSession(atSourceTime: .zero)
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                var lastReported = -1.0
                await self.pump(self.videoOutput, into: self.videoInput, id: 0) { sampleBuffer in
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
                    await self.pump(audioOutput, into: audioInput, id: 1) { sampleBuffer in
                        applyGain(gain, to: sampleBuffer)
                    }
                }
            }
        }

        try Task.checkCancellation()
        let failed = queue.sync { () -> Bool in
            guard !isCancelled, reader.status == .failed else { return false }
            writer.cancelWriting()
            return true
        }
        if failed { throw ExportError.cannotRead(reader.error) }
        try Task.checkCancellation()
        await writer.finishWriting()
        guard writer.status == .completed else { throw ExportError.cannotWrite(writer.error) }
        progress(1)
    }

    /// Annulation (nouvel export demandé) : passe par la file de travail, entre deux échantillons.
    /// Appeler `cancelReading` pendant un `copyNextSampleBuffer` sur un autre fil détruisait le lecteur
    /// en pleine lecture (plantage).
    func cancel() {
        queue.async { [self] in
            guard !isCancelled else { return }
            isCancelled = true
            pendingPumps.values.forEach { $0.resume() }
            pendingPumps.removeAll()
            reader.cancelReading()
            writer.cancelWriting()
        }
    }

    /// Recopie les échantillons de la sortie du lecteur vers l'entrée du writer, au rythme du writer.
    /// `onSample` voit (et peut modifier) chaque tampon avant son écriture.
    /// La vidéo et l'audio passent par la même file de travail que l'annulation.
    private func pump(
        _ output: AVAssetReaderOutput,
        into input: AVAssetWriterInput,
        id: Int,
        onSample: ((CMSampleBuffer) -> Void)?
    ) async {
        nonisolated(unsafe) let output = output
        nonisolated(unsafe) let input = input
        nonisolated(unsafe) let onSample = onSample
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard !isCancelled else {
                    continuation.resume()
                    return
                }
                pendingPumps[id] = continuation
                input.requestMediaDataWhenReady(on: queue) { [self] in
                    // Déjà terminé ou annulé : plus rien à lire.
                    guard pendingPumps[id] != nil else { return }
                    while input.isReadyForMoreMediaData {
                        guard !isCancelled, reader.status == .reading,
                              let sampleBuffer = output.copyNextSampleBuffer()
                        else {
                            if !isCancelled { input.markAsFinished() }
                            pendingPumps.removeValue(forKey: id)?.resume()
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
}
