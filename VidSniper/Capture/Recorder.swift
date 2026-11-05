import AVFoundation
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case displayNotFound
    case writerFailed(Error?)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .displayNotFound: String(localized: "Display not found.")
        case .writerFailed(let error): error?.localizedDescription ?? String(localized: "Couldn't write the file.")
        case .noFrames: String(localized: "No frames were captured.")
        }
    }
}

/// Capture ScreenCaptureKit écrite dans un .mov avec 3 pistes séparées : vidéo, son système, micro.
/// Tout l'état d'écriture est manipulé sur `queue`.
final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let outputURL: URL
    private let queue = DispatchQueue(label: "VidSniper.Recorder")

    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var systemAudioInput: AVAssetWriterInput?
    private var microphoneInput: AVAssetWriterInput?

    private var sessionStarted = false
    private var lastVideoTime = CMTime.invalid
    /// Horodatage (horloge système) de la première image : le zéro de la vidéo.
    private var sessionStartTime = CMTime.invalid
    private var pixelsPerPoint = 2.0
    private var pauseStartedAt: CMTime?
    /// Durée cumulée des pauses, retirée des horodatages pour ne pas laisser de trou.
    private var timeOffset = CMTime.zero

    var onInterrupted: (@Sendable (Error) -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start(region: CaptureRegion, options: CaptureOptions) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else {
            throw RecorderError.displayNotFound
        }
        // Exclut toutes les fenêtres de l'app (mini barre, cadre de la zone) de la vidéo.
        let ownApps = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])

        let scale = await MainActor.run { region.screen?.backingScaleFactor ?? 2 }
        pixelsPerPoint = scale
        let width = Self.evenPixels(region.rect.width * scale)
        let height = Self.evenPixels(region.rect.height * scale)

        let config = SCStreamConfiguration()
        config.sourceRect = region.rect
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        // Couleurs converties en sRGB par le système, puis étiquetées ainsi dans le fichier (voir `VideoColor`).
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = true
        config.queueDepth = 6
        config.capturesAudio = options.systemAudio
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.captureMicrophone = options.microphone
        if options.microphone {
            config.microphoneCaptureDeviceID = AVCaptureDevice.default(for: .audio)?.uniqueID
        }

        try setUpWriter(width: width, height: height, options: options)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if options.systemAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if options.microphone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
        self.configuration = config
    }

    // Déplacement de la zone en cours d'enregistrement : seule sa position change, la taille de sortie reste la même.
    @MainActor private var pendingSourceRect: CGRect?
    @MainActor private var isUpdatingSourceRect = false

    @MainActor
    func move(to rect: CGRect) {
        pendingSourceRect = rect
        guard !isUpdatingSourceRect else { return }
        isUpdatingSourceRect = true
        Task { @MainActor in
            // Les déplacements arrivés pendant une mise à jour sont regroupés en une seule.
            while let rect = pendingSourceRect, let stream, let configuration {
                pendingSourceRect = nil
                configuration.sourceRect = rect
                try? await stream.updateConfiguration(configuration)
            }
            isUpdatingSourceRect = false
        }
    }

    /// Instant courant dans la vidéo (pauses déduites), ou `nil` avant la première image et pendant une pause.
    func currentRecordingTime() -> Double? {
        queue.sync {
            guard sessionStarted, pauseStartedAt == nil, sessionStartTime.isValid else { return nil }
            return (Self.hostTime() - timeOffset - sessionStartTime).seconds
        }
    }

    func pause() {
        queue.async {
            self.pauseStartedAt = Self.hostTime()
        }
    }

    func resume() {
        queue.async {
            guard let pauseStartedAt = self.pauseStartedAt else { return }
            self.timeOffset = self.timeOffset + (Self.hostTime() - pauseStartedAt)
            self.pauseStartedAt = nil
        }
    }

    func stop() async throws -> RecordingResult {
        try? await stream?.stopCapture()
        stream = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { self.finishWriting(continuation) }
        }
    }

    // MARK: - Écriture

    private func setUpWriter(width: Int, height: Int, options: CaptureOptions) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        // HEVC : supporte les grandes résolutions (5K) que H.264 refuse. Le MP4 final est réencodé à l'export.
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: VideoColor.properties,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(4_000_000, width * height * 60 / 20),
                AVVideoExpectedSourceFrameRateKey: 60,
            ],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        videoInput = video

        if options.systemAudio {
            let input = Self.audioInput(channels: 2)
            writer.add(input)
            systemAudioInput = input
        }
        if options.microphone {
            let input = Self.audioInput(channels: 1)
            writer.add(input)
            microphoneInput = input
        }

        guard writer.startWriting() else { throw RecorderError.writerFailed(writer.error) }
        self.writer = writer
    }

    private static func audioInput(channels: Int) -> AVAssetWriterInput {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVEncoderBitRateKey: channels * 96_000,
            AVChannelLayoutKey: Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size),
        ])
        input.expectsMediaDataInRealTime = true
        return input
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, let writer, pauseStartedAt == nil else { return }

        switch type {
        case .screen:
            // ScreenCaptureKit envoie aussi des images "idle" sans contenu quand rien ne bouge.
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                let statusValue = attachments.first?[.status] as? Int,
                SCFrameStatus(rawValue: statusValue) == .complete
            else { return }

            if !sessionStarted {
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStartTime = sampleBuffer.presentationTimeStamp
                sessionStarted = true
            }
            if append(sampleBuffer, to: videoInput) {
                lastVideoTime = sampleBuffer.presentationTimeStamp - timeOffset
            }
        case .audio:
            guard sessionStarted else { return }
            append(sampleBuffer, to: systemAudioInput)
        case .microphone:
            guard sessionStarted else { return }
            append(sampleBuffer, to: microphoneInput)
        @unknown default:
            break
        }
    }

    @discardableResult
    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) -> Bool {
        guard let input, input.isReadyForMoreMediaData else { return false }
        guard timeOffset != .zero else { return input.append(sampleBuffer) }
        guard let shifted = Self.shift(sampleBuffer, by: timeOffset) else { return false }
        return input.append(shifted)
    }

    private func finishWriting(_ continuation: CheckedContinuation<RecordingResult, Error>) {
        guard let writer, sessionStarted else {
            writer?.cancelWriting()
            continuation.resume(throwing: RecorderError.noFrames)
            return
        }

        // Prolonge la vidéo jusqu'à l'arrêt, même si l'écran n'a pas bougé à la fin.
        let end = (pauseStartedAt ?? Self.hostTime()) - timeOffset
        writer.endSession(atSourceTime: CMTimeMaximum(end, lastVideoTime))
        [videoInput, systemAudioInput, microphoneInput].forEach { $0?.markAsFinished() }

        let result = RecordingResult(
            url: outputURL,
            hasSystemAudio: systemAudioInput != nil,
            hasMicrophone: microphoneInput != nil,
            pixelsPerPoint: pixelsPerPoint
        )
        writer.finishWriting {
            if self.writer?.status == .completed {
                continuation.resume(returning: result)
            } else {
                continuation.resume(throwing: RecorderError.writerFailed(self.writer?.error))
            }
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onInterrupted?(error)
    }

    // MARK: - Utilitaires

    private static func hostTime() -> CMTime {
        CMClockGetTime(CMClockGetHostTimeClock())
    }

    private static func evenPixels(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded()) & ~1)
    }

    private static func shift(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard var timings = try? sampleBuffer.sampleTimingInfos() else { return nil }
        for index in timings.indices {
            timings[index].presentationTimeStamp = timings[index].presentationTimeStamp - offset
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = timings[index].decodeTimeStamp - offset
            }
        }
        return try? CMSampleBuffer(copying: sampleBuffer, withNewTiming: timings)
    }
}
