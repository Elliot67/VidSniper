import AVFoundation
import Observation

/// Un morceau conservé de la vidéo source. `limit` borne le rognage : un segment issu d'une découpe
/// ne peut pas déborder sur la partie voisine.
struct Segment: Equatable {
    var range: CMTimeRange
    let limit: CMTimeRange
}

/// L'état annulable du montage.
struct EditState: Equatable {
    var segments: [Segment]
    var systemAudio: Bool
    var microphone: Bool
}

enum SegmentEdge {
    case start, end
}

/// Rognage en cours de glisser : la nouvelle plage proposée, appliquée seulement au relâchement.
struct PendingTrim: Equatable {
    let index: Int
    let edge: SegmentEdge
    let range: CMTimeRange
}

/// Niveau sonore d'une piste (crête par tranche de 1/50 s, normalisée), pour l'affichage sous la timeline.
struct AudioEnvelope: Sendable {
    static let rate = 50.0

    let values: [Float]
    /// Début de la piste audio dans la vidéo source, en secondes.
    let start: Double

    func peak(from: Double, to: Double) -> Float {
        let first = max(0, Int((from - start) * Self.rate))
        let last = min(values.count, max(first + 1, Int((to - start) * Self.rate)))
        guard first < last else { return 0 }
        return values[first..<last].max() ?? 0
    }
}

/// Montage non destructif d'un enregistrement : liste de segments + pistes audio gardées,
/// traduits en `AVMutableComposition` pour la lecture (et l'export en phase 3).
@MainActor
@Observable
final class EditorDocument {
    let recording: RecordingResult
    let player = AVPlayer()

    private(set) var state: EditState
    var selectedSegment: Int?
    /// Position de lecture, en secondes dans le montage.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var loadError: String?
    private(set) var composition: AVComposition?
    private(set) var videoAspectRatio: CGFloat = 16 / 9
    private(set) var pendingTrim: PendingTrim?
    /// Image de la source au nouveau bord quand on rallonge un clip (elle n'est pas dans le montage).
    private(set) var trimPreviewFrame: CGImage?
    private(set) var systemAudioEnvelope: AudioEnvelope?
    private(set) var microphoneEnvelope: AudioEnvelope?
    /// Vignettes de toute la vidéo source, à intervalle régulier. La timeline les place en tuiles de taille fixe :
    /// elles restent nettes au zoom, et servent aussi d'aperçu quand on rallonge un clip.
    private(set) var sourceThumbnails: [CGImage] = []
    private(set) var sourceThumbnailInterval: Double = 1

    // Zoom de la timeline, en points par seconde. `nil` : échelle par défaut.
    private(set) var pixelsPerSecond: Double?
    private(set) var viewportWidth: Double = 800
    private static let minimumDefaultScale = 30.0
    private static let maximumScale = 600.0

    private(set) var undoStack: [EditState] = []
    private(set) var redoStack: [EditState] = []

    @ObservationIgnored private let asset: AVURLAsset
    @ObservationIgnored private var videoTrack: AVAssetTrack?
    @ObservationIgnored private var videoTransform = CGAffineTransform.identity
    @ObservationIgnored private var systemAudioTrack: AVAssetTrack?
    @ObservationIgnored private var microphoneTrack: AVAssetTrack?
    @ObservationIgnored private var audioTrackRanges: [CMPersistentTrackID: CMTimeRange] = [:]
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var frameRequest = 0

    static let frameDuration = 1.0 / 60
    private static let minimumSegmentDuration = 0.1
    private static let timescale: CMTimeScale = 60_000

    init(recording: RecordingResult) {
        self.recording = recording
        asset = AVURLAsset(url: recording.url)
        state = EditState(segments: [], systemAudio: recording.hasSystemAudio, microphone: recording.hasMicrophone)
    }

    var duration: Double {
        state.segments.reduce(0) { $0 + $1.range.duration.seconds }
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasSystemAudioTrack: Bool { systemAudioTrack != nil }
    var hasMicrophoneTrack: Bool { microphoneTrack != nil }

    // MARK: - Chargement

    func load() async {
        do {
            let duration = try await asset.load(.duration)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            guard let video = videoTracks.first else {
                loadError = "La vidéo ne contient pas d'image."
                return
            }
            videoTrack = video
            videoTransform = try await video.load(.preferredTransform)
            let size = try await video.load(.naturalSize)
            if size.height > 0 { videoAspectRatio = size.width / size.height }

            // Ordre d'écriture du Recorder : son système, puis micro.
            var remaining = audioTracks.makeIterator()
            if recording.hasSystemAudio { systemAudioTrack = remaining.next() }
            if recording.hasMicrophone { microphoneTrack = remaining.next() }
            for track in audioTracks {
                audioTrackRanges[track.trackID] = try await track.load(.timeRange)
            }

            let full = CMTimeRange(start: .zero, duration: duration)
            state.segments = [Segment(range: full, limit: full)]
            observePlayer()
            rebuild(seekTo: 0)
            isReady = true
            loadEnvelopes()
            loadSourceThumbnails(duration: duration.seconds)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadSourceThumbnails(duration: Double) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 0, height: 112)
        let count = min(400, max(1, Int((duration / 0.5).rounded(.up))))
        let interval = duration / Double(count)
        let tolerance = CMTime(seconds: interval / 2, preferredTimescale: Self.timescale)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        sourceThumbnailInterval = interval

        let times = (0..<count).map { cmTime(interval * (Double($0) + 0.5)) }
        Task {
            var images: [CGImage] = []
            for await result in generator.images(for: times) {
                if let image = try? result.image { images.append(image) }
            }
            sourceThumbnails = images
        }
    }

    /// Vignette la plus proche d'un instant de la source (fonction pure, utilisable dans un `Canvas`).
    nonisolated static func thumbnail(in thumbnails: [CGImage], interval: Double, at time: Double) -> CGImage? {
        guard !thumbnails.isEmpty, interval > 0 else { return nil }
        let index = Int(time / interval)
        return thumbnails[min(max(index, 0), thumbnails.count - 1)]
    }

    /// Affiche une image de la source qui n'est pas dans le montage (seule la dernière demande compte).
    private func showSourceFrame(at seconds: Double) {
        frameRequest += 1
        let request = frameRequest
        let time = cmTime(seconds)
        let asset = asset
        Task {
            let image = await Task.detached(priority: .userInitiated) {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero
                generator.requestedTimeToleranceAfter = .zero
                return try? await generator.image(at: time).image
            }.value
            guard request == frameRequest, pendingTrim != nil else { return }
            trimPreviewFrame = image
        }
    }

    // MARK: - Zoom de la timeline

    /// Échelle qui fait tenir tout le montage dans la largeur visible.
    var fitScale: Double {
        viewportWidth / max(duration, 0.001)
    }

    /// Échelle courante : par défaut, tout le montage, sauf s'il devient trop serré (on défile alors).
    var scale: Double {
        let requested = pixelsPerSecond ?? max(fitScale, Self.minimumDefaultScale)
        return max(fitScale, min(requested, Self.maximumScale))
    }

    func setViewportWidth(_ width: Double) {
        guard width > 0, width != viewportWidth else { return }
        viewportWidth = width
    }

    func setScale(_ scale: Double) {
        pixelsPerSecond = max(fitScale, min(scale, Self.maximumScale))
    }

    func zoom(by factor: Double) {
        setScale(scale * factor)
    }

    /// Incrémenté par "Ajuster" : la timeline défile alors jusqu'au début du montage, même si l'échelle ne change pas.
    private(set) var fitRequest = 0

    func zoomToFit() {
        pixelsPerSecond = fitScale
        fitRequest += 1
    }

    private func loadEnvelopes() {
        let url = recording.url
        for (track, isMicrophone) in [(systemAudioTrack, false), (microphoneTrack, true)] {
            guard let track, let range = audioTrackRanges[track.trackID] else { continue }
            let trackID = track.trackID
            let start = range.start.seconds
            Task {
                let values = await Task.detached(priority: .utility) {
                    await Self.readEnvelope(url: url, trackID: trackID)
                }.value
                let envelope = AudioEnvelope(values: values, start: start)
                if isMicrophone {
                    microphoneEnvelope = envelope
                } else {
                    systemAudioEnvelope = envelope
                }
            }
        }
    }

    /// Lit la piste en PCM mono 8 kHz et garde la crête de chaque tranche, normalisée sur la piste.
    nonisolated private static func readEnvelope(url: URL, trackID: CMPersistentTrackID) async -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTrack(withTrackID: trackID),
              let reader = try? AVAssetReader(asset: asset)
        else { return [] }

        let sampleRate = 8_000
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { return [] }
        reader.add(output)
        guard reader.startReading() else { return [] }

        let samplesPerBucket = Int(Double(sampleRate) / AudioEnvelope.rate)
        var values: [Float] = []
        var peak: Float = 0
        var count = 0
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            samples.withUnsafeMutableBytes { buffer in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
            }
            for sample in samples {
                peak = max(peak, abs(sample))
                count += 1
                if count == samplesPerBucket {
                    values.append(peak)
                    peak = 0
                    count = 0
                }
            }
        }

        // Normalisation sur la piste, puis échelle en décibels (-40 dB → 0) : une voix peu forte reste bien visible.
        guard let maximum = values.max(), maximum > 0.001 else { return values.map { _ in 0 } }
        return values.map { value in
            let normalized = min(1, value / maximum)
            guard normalized > 0 else { return 0 }
            return max(0, 1 + 20 * log10(normalized) / 40)
        }
    }

    func close() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        player.replaceCurrentItem(with: nil)
    }

    private func observePlayer() {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 30),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.currentTime = min(time.seconds, self.duration)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let finishedItem = (notification.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let current = self.player.currentItem,
                      finishedItem == ObjectIdentifier(current)
                else { return }
                self.isPlaying = false
                self.currentTime = self.duration
            }
        }
    }

    // MARK: - Lecture

    func togglePlay() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if currentTime >= duration - Self.frameDuration { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to time: Double) {
        let clamped = min(max(time, 0), duration)
        currentTime = clamped
        player.seek(to: cmTime(clamped), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(by seconds: Double) {
        if isPlaying { togglePlay() }
        seek(to: currentTime + seconds)
    }

    // MARK: - Segments

    /// Début de chaque segment dans le temps du montage.
    var segmentStarts: [Double] {
        var starts: [Double] = []
        var position = 0.0
        for segment in state.segments {
            starts.append(position)
            position += segment.range.duration.seconds
        }
        return starts
    }

    func segmentIndex(at time: Double) -> Int? {
        let starts = segmentStarts
        guard !starts.isEmpty else { return nil }
        return starts.lastIndex { $0 <= time } ?? 0
    }

    /// Découpe le segment sous la tête de lecture en deux.
    func cutAtPlayhead() {
        guard let index = segmentIndex(at: currentTime) else { return }
        let segment = state.segments[index]
        let offset = currentTime - segmentStarts[index]
        guard offset > Self.minimumSegmentDuration,
              offset < segment.range.duration.seconds - Self.minimumSegmentDuration
        else { return }

        let split = segment.range.start + cmTime(offset)
        let left = Segment(
            range: CMTimeRange(start: segment.range.start, end: split),
            limit: CMTimeRange(start: segment.limit.start, end: split)
        )
        let right = Segment(
            range: CMTimeRange(start: split, end: segment.range.end),
            limit: CMTimeRange(start: split, end: segment.limit.end)
        )
        apply { $0.segments.replaceSubrange(index...index, with: [left, right]) }
    }

    func deleteSelectedSegment() {
        guard let index = selectedSegment, state.segments.indices.contains(index), state.segments.count > 1 else { return }
        let start = segmentStarts[index]
        apply(seekTo: start) { $0.segments.remove(at: index) }
    }

    /// Aperçu d'un rognage pendant le glisser, sans toucher au montage : le clip garde sa place dans la
    /// timeline et la vidéo montre l'image du nouveau bord. `delta` en secondes.
    func previewTrim(segment index: Int, edge: SegmentEdge, by delta: Double) {
        guard state.segments.indices.contains(index) else { return }
        if isPlaying { togglePlay() }
        let original = state.segments[index]
        let range = original.range
        let newRange: CMTimeRange
        switch edge {
        case .start:
            let start = min(
                max(range.start.seconds + delta, original.limit.start.seconds),
                range.end.seconds - Self.minimumSegmentDuration
            )
            newRange = CMTimeRange(start: cmTime(start), end: range.end)
        case .end:
            let end = max(
                min(range.end.seconds + delta, original.limit.end.seconds),
                range.start.seconds + Self.minimumSegmentDuration
            )
            newRange = CMTimeRange(start: range.start, end: cmTime(end))
        }
        pendingTrim = PendingTrim(index: index, edge: edge, range: newRange)

        // Montre l'image du nouveau bord : dans le montage si on raccourcit, sinon directement depuis la source.
        let edgeTime = edge == .start ? newRange.start.seconds : newRange.end.seconds - Self.frameDuration
        let offset = edgeTime - range.start.seconds
        if offset >= 0, offset <= range.duration.seconds {
            trimPreviewFrame = nil
            seek(to: segmentStarts[index] + offset)
        } else {
            showSourceFrame(at: edgeTime)
        }
    }

    /// Applique le rognage proposé, au relâchement de la poignée.
    func commitTrim() {
        guard let trim = pendingTrim else { return }
        pendingTrim = nil
        trimPreviewFrame = nil
        guard state.segments.indices.contains(trim.index), state.segments[trim.index].range != trim.range else { return }

        // Les segments précédents ne bougent pas : la tête de lecture va sur le nouveau bord.
        let segmentStart = segmentStarts[trim.index]
        let time = trim.edge == .start
            ? segmentStart
            : segmentStart + trim.range.duration.seconds - Self.frameDuration
        apply(seekTo: time) { $0.segments[trim.index].range = trim.range }
        selectedSegment = trim.index
    }

    // MARK: - Audio

    func setSystemAudio(_ enabled: Bool) {
        apply(seekTo: currentTime) { $0.systemAudio = enabled }
    }

    func setMicrophone(_ enabled: Bool) {
        apply(seekTo: currentTime) { $0.microphone = enabled }
    }

    // MARK: - Annuler / rétablir

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        selectedSegment = nil
        rebuild(seekTo: currentTime)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        selectedSegment = nil
        rebuild(seekTo: currentTime)
    }

    private func apply(seekTo time: Double? = nil, _ change: (inout EditState) -> Void) {
        var newState = state
        change(&newState)
        guard newState != state else { return }
        undoStack.append(state)
        redoStack.removeAll()
        state = newState
        selectedSegment = nil
        rebuild(seekTo: time ?? currentTime)
    }

    // MARK: - Composition

    private func rebuild(seekTo time: Double) {
        guard let videoTrack else { return }
        let wasPlaying = isPlaying
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }
        video.preferredTransform = videoTransform

        let audioSources = [
            state.systemAudio ? systemAudioTrack : nil,
            state.microphone ? microphoneTrack : nil,
        ].compactMap { $0 }
        let audioTracks = audioSources.map { source in
            (source, composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        }

        var cursor = CMTime.zero
        for segment in state.segments {
            try? video.insertTimeRange(segment.range, of: videoTrack, at: cursor)
            for (source, track) in audioTracks {
                // Une piste audio peut être un peu plus courte que la vidéo.
                guard let track, let available = audioTrackRanges[source.trackID] else { continue }
                let range = segment.range.intersection(available)
                guard !range.isEmpty else { continue }
                try? track.insertTimeRange(range, of: source, at: cursor + (range.start - segment.range.start))
            }
            cursor = cursor + segment.range.duration
        }

        self.composition = composition
        player.replaceCurrentItem(with: AVPlayerItem(asset: composition))
        seek(to: time)
        if wasPlaying { player.play() }
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: Self.timescale)
    }
}
