import AVFoundation
import Observation

/// Un morceau conservé de la vidéo source. Jusqu'où il peut être rallongé dépend de ses voisins du moment
/// (voir `EditorDocument.limit(ofSegment:)`) : supprimer un voisin rend sa partie récupérable.
struct Segment: Equatable {
    var range: CMTimeRange
}

/// L'état annulable du montage.
struct EditState: Equatable {
    var segments: [Segment]
    var systemAudio: Bool
    var microphone: Bool
    var annotations: [Annotation] = []
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

/// Analyse d'une piste audio : crête par tranche de 1/50 s (affichage) et niveau moyen des passages
/// actifs (normalisation automatique).
struct AudioEnvelope: Sendable {
    static let rate = 50.0
    static let silence: Float = -100

    /// Crête de chaque tranche, en dBFS.
    let decibels: [Float]
    /// Début de la piste audio dans la vidéo source, en secondes.
    let start: Double
    /// Niveau moyen (RMS, dBFS) des passages actifs. `nil` : piste quasi muette (micro allumé sans parler,
    /// navigateur silencieux…), qu'on ne touche pas pour ne pas faire remonter du souffle.
    let loudness: Double?

    func peak(from: Double, to: Double) -> Float {
        let first = max(0, Int((from - start) * Self.rate))
        let last = min(decibels.count, max(first + 1, Int((to - start) * Self.rate)))
        guard first < last else { return Self.silence }
        return decibels[first..<last].max() ?? Self.silence
    }
}

/// Montage non destructif d'un enregistrement : liste de segments + pistes audio gardées,
/// traduits en `AVMutableComposition` pour la lecture (et l'export en phase 3).
@MainActor
@Observable
final class EditorDocument {
    let recording: RecordingResult
    let player = AVPlayer()
    let export: ExportModel

    private(set) var state: EditState
    var selectedSegment: Int?

    /// Balance entre les deux pistes : -1 = la voix ressort, +1 = le son système ressort, 0 = même niveau perçu.
    /// Mémorisée pour toutes les vidéos, hors annuler/rétablir (un curseur produirait des dizaines d'étapes).
    var balance: Double {
        didSet {
            UserDefaults.standard.set(balance, forKey: "audioBalance")
            applyGains()
        }
    }

    static let defaultBalance = -0.5
    /// Niveau visé pour chaque piste active (RMS des passages actifs).
    private static let targetLoudness = -20.0
    /// Plafond de l'amplification automatique : au-delà, on ferait surtout remonter le bruit de fond.
    private static let maximumBoost = 18.0
    /// Écart maximal entre les deux pistes aux extrémités de la balance.
    static let balanceRange = 20.0
    /// Position de lecture, en secondes dans le montage.
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false
    private(set) var isReady = false
    private(set) var loadError: String?
    private(set) var composition: AVComposition?
    private(set) var videoAspectRatio: CGFloat = 16 / 9
    @ObservationIgnored private var videoPixelWidth: CGFloat = 0
    /// Mise en évidence des clics, mémorisée d'une vidéo à l'autre (hors annuler/rétablir).
    private(set) var showClicks = UserDefaults.standard.object(forKey: "showClicks") as? Bool ?? true
    /// Couleur des cercles de clic, mémorisée d'une vidéo à l'autre.
    private(set) var clickColor = AnnotationColor(rawValue: UserDefaults.standard.string(forKey: "clickColor") ?? "") ?? .violet

    // Annotations : outil "Tracer" armé (le prochain glisser sur la vidéo en crée une), sélection,
    // réglages des prochaines (style, forme, couleur : un seul élément, plusieurs rendus).
    private(set) var isDrawingAnnotation = false
    var selectedAnnotationID: UUID?
    private(set) var newAnnotationStyle = AnnotationStyle(
        rawValue: UserDefaults.standard.string(forKey: "annotationStyle") ?? ""
    ) ?? .frame
    private(set) var newAnnotationShape = AnnotationShape(
        rawValue: UserDefaults.standard.string(forKey: "annotationShape") ?? ""
    ) ?? .rectangle
    private(set) var newAnnotationColor = AnnotationColor(
        rawValue: UserDefaults.standard.string(forKey: "annotationColor") ?? ""
    ) ?? .violet
    @ObservationIgnored private var annotationSnapshot: EditState?
    @ObservationIgnored private var videoDisplaySize: CGSize = .zero
    /// Durée de la vidéo source (borne des annotations).
    @ObservationIgnored private(set) var sourceDuration: Double = 0
    /// Toute la vidéo source : borne des segments au début et à la fin du montage.
    @ObservationIgnored private var sourceTimeRange = CMTimeRange.zero
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
    /// Pistes audio de la composition courante : identifiant et source (micro ou son système).
    @ObservationIgnored private var compositionAudioTracks: [(trackID: CMPersistentTrackID, isMicrophone: Bool)] = []
    /// Gains lus en continu par la lecture : bouger la balance change le son sans reconstruire le mix.
    @ObservationIgnored private let systemAudioGain = AudioGain(1)
    @ObservationIgnored private let microphoneGain = AudioGain(1)
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var frameRequest = 0

    static let frameDuration = 1.0 / 60
    private static let minimumSegmentDuration = 0.1
    private static let timescale: CMTimeScale = 60_000

    init(recording: RecordingResult) {
        self.recording = recording
        export = ExportModel(recording: recording)
        asset = AVURLAsset(url: recording.url)
        state = EditState(segments: [], systemAudio: recording.hasSystemAudio, microphone: recording.hasMicrophone)
        balance = UserDefaults.standard.object(forKey: "audioBalance") as? Double ?? Self.defaultBalance
    }

    // MARK: - Niveaux audio

    /// La balance n'a de sens que si les deux pistes sont gardées et contiennent vraiment du son.
    var isBalanceAvailable: Bool {
        state.systemAudio && state.microphone
            && systemAudioEnvelope?.loudness != nil && microphoneEnvelope?.loudness != nil
    }

    /// Piste analysée et quasi muette.
    func isSilent(microphone: Bool) -> Bool {
        let envelope = microphone ? microphoneEnvelope : systemAudioEnvelope
        return envelope != nil && envelope?.loudness == nil
    }

    /// Gain appliqué à une piste : normalisation vers le niveau cible (piste active seulement, plafonnée),
    /// puis atténuation de la piste mise en retrait par la balance.
    func gainDecibels(microphone: Bool) -> Double {
        let envelope = microphone ? microphoneEnvelope : systemAudioEnvelope
        var gain = 0.0
        if let loudness = envelope?.loudness {
            gain = min(Self.maximumBoost, max(-30, Self.targetLoudness - loudness))
        }
        if isBalanceAvailable {
            let offset = balance * Self.balanceRange
            gain += microphone ? min(0, -offset) : min(0, offset)
        }
        return gain
    }

    private func linearGain(microphone: Bool) -> Float {
        Float(pow(10, gainDecibels(microphone: microphone) / 20))
    }

    private var playbackAudioMix: AVAudioMix {
        AVAudioMix.with(gains: compositionAudioTracks.map { track in
            (track.trackID, track.isMicrophone ? microphoneGain : systemAudioGain)
        })
    }

    private var audioVolumes: [AudioTrackVolume] {
        compositionAudioTracks.map { track in
            AudioTrackVolume(trackID: track.trackID, volume: linearGain(microphone: track.isMicrophone))
        }
    }

    private func updateGainValues() {
        systemAudioGain.value = linearGain(microphone: false)
        microphoneGain.value = linearGain(microphone: true)
    }

    private func applyGains() {
        updateGainValues()
        export.volumesChanged(audioVolumes)
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
                loadError = String(localized: "The video contains no image.")
                return
            }
            videoTrack = video
            videoTransform = try await video.load(.preferredTransform)
            // Taille affichée : une vidéo filmée en portrait est stockée couchée, avec une rotation à appliquer.
            let naturalSize = try await video.load(.naturalSize)
            let rotated = CGRect(origin: .zero, size: naturalSize).applying(videoTransform)
            let size = CGSize(width: abs(rotated.width), height: abs(rotated.height))
            if size.height > 0 { videoAspectRatio = size.width / size.height }
            videoPixelWidth = size.width
            videoDisplaySize = size
            sourceDuration = duration.seconds
            export.videoSize = size

            // Ordre d'écriture du Recorder : son système, puis micro.
            var remaining = audioTracks.makeIterator()
            if recording.hasSystemAudio { systemAudioTrack = remaining.next() }
            if recording.hasMicrophone { microphoneTrack = remaining.next() }
            for track in audioTracks {
                audioTrackRanges[track.trackID] = try await track.load(.timeRange)
            }

            let full = CMTimeRange(start: .zero, duration: duration)
            sourceTimeRange = full
            state.segments = [Segment(range: full)]
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
                let analysis = await Task.detached(priority: .utility) {
                    await Self.analyze(url: url, trackID: trackID)
                }.value
                let envelope = AudioEnvelope(decibels: analysis.decibels, start: start, loudness: analysis.loudness)
                if isMicrophone {
                    microphoneEnvelope = envelope
                } else {
                    systemAudioEnvelope = envelope
                }
                if envelope.loudness == nil {
                    disableSilentTrack(microphone: isMicrophone)
                }
                // Les niveaux mesurés donnent les gains de normalisation.
                applyGains()
            }
        }
    }

    /// Lit la piste en PCM mono 8 kHz. Par tranche de 1/50 s : crête (affichage) et RMS (activité).
    /// Une piste est active si elle dépasse -45 dBFS pendant au moins 1 s au total (moins sur une vidéo courte).
    nonisolated private static func analyze(
        url: URL,
        trackID: CMPersistentTrackID
    ) async -> (decibels: [Float], loudness: Double?) {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTrack(withTrackID: trackID),
              let reader = try? AVAssetReader(asset: asset)
        else { return ([], nil) }

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
        guard reader.canAdd(output) else { return ([], nil) }
        reader.add(output)
        guard reader.startReading() else { return ([], nil) }

        let samplesPerBucket = Int(Double(sampleRate) / AudioEnvelope.rate)
        let activityThreshold = -45.0
        var decibels: [Float] = []
        var activePower: [Double] = []
        var peak: Float = 0
        var sumOfSquares: Double = 0
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
                sumOfSquares += Double(sample * sample)
                count += 1
                if count == samplesPerBucket {
                    decibels.append(peak > 0 ? max(AudioEnvelope.silence, 20 * log10(peak)) : AudioEnvelope.silence)
                    let power = sumOfSquares / Double(count)
                    if power > 0, 10 * log10(power) > activityThreshold {
                        activePower.append(power)
                    }
                    peak = 0
                    sumOfSquares = 0
                    count = 0
                }
            }
        }

        let totalSeconds = Double(decibels.count) / AudioEnvelope.rate
        let activeSeconds = Double(activePower.count) / AudioEnvelope.rate
        let minimumActive = min(1, max(0.3, totalSeconds * 0.03))
        guard activeSeconds >= minimumActive else { return (decibels, nil) }
        let meanPower = activePower.reduce(0, +) / Double(activePower.count)
        return (decibels, 10 * log10(meanPower))
    }

    func close() {
        export.cancel()
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
        let left = Segment(range: CMTimeRange(start: segment.range.start, end: split))
        let right = Segment(range: CMTimeRange(start: split, end: segment.range.end))
        apply { $0.segments.replaceSubrange(index...index, with: [left, right]) }
    }

    /// Jusqu'où un segment peut être rallongé, dans la source : jusqu'à la fin du segment précédent et au début
    /// du suivant (ou aux bords de la vidéo). Les segments restent dans l'ordre de la source, donc deux
    /// segments ne se chevauchent jamais, et la partie d'un voisin supprimé redevient accessible.
    func limit(ofSegment index: Int) -> CMTimeRange {
        let segments = state.segments
        guard segments.indices.contains(index) else { return sourceTimeRange }
        let start = index > 0 ? segments[index - 1].range.end : sourceTimeRange.start
        let end = index < segments.count - 1 ? segments[index + 1].range.start : sourceTimeRange.end
        return CMTimeRange(start: start, end: end)
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
        let limit = limit(ofSegment: index)
        let newRange: CMTimeRange
        switch edge {
        case .start:
            let start = min(
                max(range.start.seconds + delta, limit.start.seconds),
                range.end.seconds - Self.minimumSegmentDuration
            )
            newRange = CMTimeRange(start: cmTime(start), end: range.end)
        case .end:
            let end = max(
                min(range.end.seconds + delta, limit.end.seconds),
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
        guard !(enabled && isSilent(microphone: false)) else { return }
        apply(seekTo: currentTime) { $0.systemAudio = enabled }
    }

    func setMicrophone(_ enabled: Bool) {
        guard !(enabled && isSilent(microphone: true)) else { return }
        apply(seekTo: currentTime) { $0.microphone = enabled }
    }

    /// Piste sans son : coupée d'office et pour de bon (dans l'historique aussi, pour qu'annuler ne la
    /// réactive pas). Ce n'est pas une modification de l'utilisateur : pas d'étape d'annulation.
    private func disableSilentTrack(microphone: Bool) {
        func disable(_ state: inout EditState) {
            if microphone {
                state.microphone = false
            } else {
                state.systemAudio = false
            }
        }
        let wasEnabled = microphone ? state.microphone : state.systemAudio
        disable(&state)
        for index in undoStack.indices { disable(&undoStack[index]) }
        for index in redoStack.indices { disable(&redoStack[index]) }
        if wasEnabled { rebuild(seekTo: currentTime) }
    }

    func setShowClicks(_ enabled: Bool) {
        guard showClicks != enabled else { return }
        showClicks = enabled
        UserDefaults.standard.set(enabled, forKey: "showClicks")
        rebuild(seekTo: currentTime)
    }

    func setClickColor(_ color: AnnotationColor) {
        guard clickColor != color else { return }
        clickColor = color
        UserDefaults.standard.set(color.rawValue, forKey: "clickColor")
        // L'aperçu des clics passe par Core Image : il faut reconstruire l'élément lu.
        rebuild(seekTo: currentTime)
    }

    // MARK: - Annotations

    /// Correspondance montage → source, pour placer les annotations (attachées au contenu).
    var timeMapping: TimeMapping {
        let starts = segmentStarts
        return TimeMapping(pieces: state.segments.enumerated().map { index, segment in
            TimeMapping.Piece(
                compositionStart: starts[index],
                sourceStart: segment.range.start.seconds,
                duration: segment.range.duration.seconds
            )
        })
    }

    var selectedAnnotation: Annotation? {
        state.annotations.first { $0.id == selectedAnnotationID }
    }

    /// Arme l'outil "Tracer" (ou le désarme) : le prochain glisser sur la vidéo crée une annotation.
    func toggleAnnotationDrawing() {
        isDrawingAnnotation.toggle()
        if isDrawingAnnotation {
            selectedAnnotationID = nil
            if isPlaying { togglePlay() }
        }
    }

    /// Esc : désarme l'outil, puis désélectionne.
    func cancelAnnotationInteraction() {
        if isDrawingAnnotation {
            isDrawingAnnotation = false
        } else {
            selectedAnnotationID = nil
        }
    }

    /// Crée une annotation à la tête de lecture, pour la durée par défaut, avec les réglages courants.
    func createAnnotation(in rect: CGRect) {
        guard isDrawingAnnotation, let start = timeMapping.sourceTime(at: currentTime) else { return }
        let end = min(start + Annotation.defaultDuration, sourceDuration)
        let annotation = Annotation(
            id: UUID(),
            style: newAnnotationStyle,
            shape: newAnnotationShape,
            color: newAnnotationColor,
            rect: rect,
            start: min(start, end - Annotation.minimumDuration),
            end: end
        )
        applyAnnotations { $0.annotations.append(annotation) }
        isDrawingAnnotation = false
        selectedAnnotationID = annotation.id
    }

    /// Rendu (cadre ou projecteur) de l'annotation sélectionnée, ou des prochaines si rien n'est sélectionné.
    func setAnnotationStyle(_ style: AnnotationStyle) {
        if let id = selectedAnnotationID {
            applyAnnotations { state in
                if let index = state.annotations.firstIndex(where: { $0.id == id }) {
                    state.annotations[index].style = style
                }
            }
        }
        newAnnotationStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: "annotationStyle")
    }

    func deleteSelectedAnnotation() {
        guard let id = selectedAnnotationID else { return }
        applyAnnotations { $0.annotations.removeAll { $0.id == id } }
        selectedAnnotationID = nil
    }

    /// Forme de l'annotation sélectionnée, ou des prochaines si rien n'est sélectionné.
    func setAnnotationShape(_ shape: AnnotationShape) {
        if let id = selectedAnnotationID {
            applyAnnotations { state in
                if let index = state.annotations.firstIndex(where: { $0.id == id }) {
                    state.annotations[index].shape = shape
                }
            }
        }
        newAnnotationShape = shape
        UserDefaults.standard.set(shape.rawValue, forKey: "annotationShape")
    }

    /// Couleur du cadre sélectionné, ou des prochains si rien n'est sélectionné.
    func setAnnotationColor(_ color: AnnotationColor) {
        if let id = selectedAnnotationID {
            applyAnnotations { state in
                if let index = state.annotations.firstIndex(where: { $0.id == id }) {
                    state.annotations[index].color = color
                }
            }
        }
        newAnnotationColor = color
        UserDefaults.standard.set(color.rawValue, forKey: "annotationColor")
    }

    /// Modification continue (déplacement, redimensionnement, durée) : une seule étape d'annulation à la fin.
    func beginAnnotationEdit() {
        annotationSnapshot = state
        if isPlaying { togglePlay() }
    }

    func editAnnotation(_ id: UUID, _ change: (inout Annotation) -> Void) {
        guard let index = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        change(&state.annotations[index])
    }

    func endAnnotationEdit() {
        guard let snapshot = annotationSnapshot else { return }
        annotationSnapshot = nil
        guard snapshot != state else { return }
        undoStack.append(snapshot)
        redoStack.removeAll()
        notifyEffectsChanged()
    }

    /// Les annotations ne touchent pas à la composition : pas de reconstruction, seul l'export est relancé.
    private func applyAnnotations(_ change: (inout EditState) -> Void) {
        var newState = state
        change(&newState)
        guard newState != state else { return }
        undoStack.append(state)
        redoStack.removeAll()
        state = newState
        notifyEffectsChanged()
    }

    private func notifyEffectsChanged() {
        export.effectsChanged(signature: editSignature, clicks: clickOverlay, annotations: annotationOverlay)
    }

    private var annotationOverlay: AnnotationOverlay? {
        guard !state.annotations.isEmpty, videoDisplaySize != .zero else { return nil }
        return AnnotationOverlay(annotations: state.annotations, mapping: timeMapping, videoSize: videoDisplaySize)
    }

    // MARK: - Annuler / rétablir

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(state)
        state = previous
        selectedSegment = nil
        dropMissingAnnotationSelection()
        rebuild(seekTo: currentTime)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        selectedSegment = nil
        dropMissingAnnotationSelection()
        rebuild(seekTo: currentTime)
    }

    private func dropMissingAnnotationSelection() {
        if selectedAnnotation == nil { selectedAnnotationID = nil }
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

        compositionAudioTracks = audioTracks.compactMap { source, track in
            track.map { ($0.trackID, source === microphoneTrack) }
        }
        // Couper une piste peut rendre la balance inapplicable : les gains de l'autre piste changent.
        updateGainValues()

        self.composition = composition
        let item = AVPlayerItem(asset: composition)
        item.audioMix = playbackAudioMix
        player.replaceCurrentItem(with: item)
        seek(to: time)
        if wasPlaying { player.play() }

        // L'export travaille sur une copie figée, indépendante des prochaines modifications.
        guard let snapshot = composition.copy() as? AVComposition else { return }
        let clicks = clickOverlay
        export.compositionChanged(
            snapshot,
            signature: editSignature,
            duration: duration,
            hasAudio: !audioSources.isEmpty,
            volumes: audioVolumes,
            clicks: clicks,
            annotations: annotationOverlay
        )

        // Aperçu fidèle : les clics sont dessinés par la même composition Core Image que l'export.
        if let clicks {
            let source = UncheckedSendable<AVAsset>(snapshot)
            Task {
                guard let videoComposition = try? await VideoEffects.videoComposition(
                    for: source, clicks: clicks, renderSize: nil, frameRate: nil
                ), player.currentItem === item else { return }
                item.videoComposition = videoComposition
            }
        }
    }

    /// Description textuelle du montage (segments à la milliseconde, pistes gardées, clics, annotations),
    /// clé du cache d'export.
    private var editSignature: String {
        let segments = state.segments
            .map { String(format: "%.3f-%.3f", $0.range.start.seconds, $0.range.end.seconds) }
            .joined(separator: ",")
        let clicks = clickOverlay == nil ? "0" : clickColor.rawValue
        let annotations = state.annotations.map { annotation in
            let rect = annotation.rect
            return String(
                format: "%@%@%@:%.4f,%.4f,%.4f,%.4f:%.3f-%.3f",
                annotation.style.rawValue, annotation.shape.rawValue, annotation.color.rawValue,
                rect.minX, rect.minY, rect.width, rect.height, annotation.start, annotation.end
            )
        }.joined(separator: ";")
        return "\(segments)|s\(state.systemAudio ? 1 : 0)m\(state.microphone ? 1 : 0)c\(clicks)|\(annotations)"
    }

    // MARK: - Clics

    var hasClicks: Bool { !recording.clicks.isEmpty }

    /// Clics en temps du montage : chaque clic tombant dans un segment gardé y est replacé
    /// (ligne "Clics" de la timeline, et cercles dessinés dans la vidéo).
    var compositionClicks: [ClickMark] {
        let starts = segmentStarts
        var clicks: [ClickMark] = []
        for (index, segment) in state.segments.enumerated() {
            let start = segment.range.start.seconds
            let end = segment.range.end.seconds
            for click in recording.clicks where click.time >= start && click.time < end {
                clicks.append(ClickMark(time: starts[index] + click.time - start, x: click.x, y: click.y))
            }
        }
        return clicks
    }

    /// Cercles de clic dessinés dans la vidéo (si la mise en évidence est activée).
    private var clickOverlay: ClickOverlay? {
        guard showClicks, hasClicks, videoPixelWidth > 0 else { return nil }
        let clicks = compositionClicks
        guard !clicks.isEmpty else { return nil }
        // Rayon de 22 points d'écran, quelle que soit la taille de la zone.
        return ClickOverlay(clicks: clicks, radius: 22 * recording.pixelsPerPoint / videoPixelWidth, color: clickColor)
    }

    /// Vignette du début du montage (aperçu de la vidéo à glisser).
    var firstFrameThumbnail: CGImage? {
        guard let first = state.segments.first else { return nil }
        return Self.thumbnail(in: sourceThumbnails, interval: sourceThumbnailInterval, at: first.range.start.seconds)
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: Self.timescale)
    }
}
