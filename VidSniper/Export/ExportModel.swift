import AVFoundation
import AppKit
import Observation
import UniformTypeIdentifiers

/// Export du montage d'un éditeur : réglages, poids estimé, MP4 regénéré en arrière-plan à chaque
/// modification (avec un délai), puis glisser, copier ou enregistrer le fichier.
@MainActor
@Observable
final class ExportModel {
    enum Status: Equatable {
        case waiting
        case exporting(progress: Double)
        case ready(url: URL, bytes: Int64)
        case failed(String)
    }

    var resolution: ExportResolution {
        didSet {
            UserDefaults.standard.set(resolution.rawValue, forKey: "exportResolution")
            scheduleExport()
        }
    }

    var quality: ExportQuality {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "exportQuality")
            scheduleExport()
        }
    }

    private(set) var status: Status = .waiting {
        didSet {
            let url = readyURL
            if url != Self.readyURL(of: oldValue) { onReadyURLChange?(url) }
        }
    }
    /// Prévient l'éditeur dès qu'un MP4 est prêt (ou ne l'est plus), pour le charger dans l'onglet Export.
    @ObservationIgnored var onReadyURLChange: ((URL?) -> Void)?
    /// Poids réel / poids estimé du dernier export : corrige l'estimation des autres réglages.
    private var estimateCorrection = 1.0
    private(set) var justCopied = false
    var videoSize: CGSize = .zero

    @ObservationIgnored private var composition: AVComposition?
    @ObservationIgnored private var duration: Double = 0
    @ObservationIgnored private var hasAudio = false
    @ObservationIgnored private var volumes: [AudioTrackVolume] = []
    /// Clics à dessiner, déjà en temps du montage (`nil` : mise en évidence désactivée ou aucun clic).
    @ObservationIgnored private var clicks: ClickOverlay?
    @ObservationIgnored private var annotations: AnnotationOverlay?
    /// Description du montage (segments, pistes gardées, effets) : avec les réglages, elle identifie un export.
    @ObservationIgnored private var signature = ""
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var copiedTask: Task<Void, Never>?
    @ObservationIgnored private var isClosed = false
    /// Le nom du fichier est celui que verront les destinataires (Slack, Jira…).
    @ObservationIgnored private let fileName: String
    /// Exports déjà faits pendant la session : revenir à un réglage déjà essayé est instantané.
    @ObservationIgnored private var cache: [String: (url: URL, bytes: Int64)] = [:]

    init(recording: RecordingResult) {
        let defaults = UserDefaults.standard
        resolution = ExportResolution(rawValue: defaults.string(forKey: "exportResolution") ?? "") ?? .screen
        quality = ExportQuality(rawValue: defaults.string(forKey: "exportQuality") ?? "") ?? .balanced
        pixelsPerPoint = recording.pixelsPerPoint
        fileName = recording.url.deletingPathExtension().lastPathComponent + ".mp4"
    }

    /// Pixels de la vidéo par point d'écran : 2 pour un enregistrement Retina, 1 pour une vidéo importée.
    let pixelsPerPoint: Double

    /// Le choix Retina / Écran n'a de sens que si la vidéo a plus de pixels que l'écran.
    var hasScreenResolution: Bool {
        pixelsPerPoint > 1
    }

    /// Définition réellement utilisée (toujours la pleine définition sans enregistrement Retina).
    private var effectiveResolution: ExportResolution {
        hasScreenResolution ? resolution : .full
    }

    private var cacheKey: String {
        cacheKey(resolution: effectiveResolution, quality: quality)
    }

    private func cacheKey(resolution: ExportResolution, quality: ExportQuality) -> String {
        let volumes = volumes.map { "\($0.trackID):\($0.volume)" }.joined(separator: ",")
        return "\(signature)|\(resolution.rawValue)|\(quality.rawValue)|\(volumes)"
    }

    /// Chaque export a son propre dossier, pour garder le même nom de fichier dans tous les cas.
    private func outputURL(for key: String) -> URL {
        let folder = RecordingStore.exportsDirectory
            .appending(path: String(UInt(bitPattern: key.hashValue), radix: 16), directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: fileName)
    }

    var plan: ExportPlan? {
        plan(resolution: effectiveResolution, quality: quality)
    }

    func plan(resolution: ExportResolution, quality: ExportQuality) -> ExportPlan? {
        guard videoSize != .zero, duration > 0 else { return nil }
        return ExportPlan(
            sourceSize: videoSize,
            pixelsPerPoint: pixelsPerPoint,
            duration: duration,
            hasAudio: hasAudio,
            resolution: resolution,
            quality: quality
        )
    }

    /// Poids d'un réglage pour le montage actuel : réel s'il a déjà été exporté pendant la session,
    /// sinon estimé (corrigé d'après le dernier export réel).
    func weight(resolution: ExportResolution, quality: ExportQuality) -> (bytes: Int64, isEstimate: Bool)? {
        let resolution = hasScreenResolution ? resolution : .full
        if let cached = cache[cacheKey(resolution: resolution, quality: quality)] {
            return (cached.bytes, false)
        }
        guard let plan = plan(resolution: resolution, quality: quality) else { return nil }
        return (Int64(Double(plan.estimatedBytes) * estimateCorrection), true)
    }

    /// Appelé par l'éditeur à chaque reconstruction du montage.
    func compositionChanged(
        _ composition: AVComposition,
        signature: String,
        duration: Double,
        hasAudio: Bool,
        volumes: [AudioTrackVolume],
        clicks: ClickOverlay?,
        annotations: AnnotationOverlay?
    ) {
        self.composition = composition
        self.signature = signature
        self.duration = duration
        self.hasAudio = hasAudio
        self.volumes = volumes
        self.clicks = clicks
        self.annotations = annotations
        scheduleExport()
    }

    /// Appelé quand les effets changent (annotations, couleur des clics) sans reconstruction du montage.
    func effectsChanged(signature: String, clicks: ClickOverlay?, annotations: AnnotationOverlay?) {
        guard signature != self.signature else { return }
        self.signature = signature
        self.clicks = clicks
        self.annotations = annotations
        scheduleExport()
    }

    /// Appelé quand un volume change, sans reconstruction du montage.
    func volumesChanged(_ volumes: [AudioTrackVolume]) {
        guard volumes != self.volumes else { return }
        self.volumes = volumes
        scheduleExport()
    }

    /// Éditeur fermé : l'export en cours est abandonné, et plus aucun n'est lancé (l'analyse du son, qui se
    /// termine parfois après la fermeture, relançait sinon un export que personne n'annulait).
    func close() {
        isClosed = true
        exportTask?.cancel()
        exportTask = nil
    }

    private func scheduleExport() {
        exportTask?.cancel()
        guard !isClosed, let composition, let plan else { return }
        justCopied = false

        let key = cacheKey
        if let cached = cache[key], FileManager.default.fileExists(atPath: cached.url.path) {
            status = .ready(url: cached.url, bytes: cached.bytes)
            return
        }
        status = .exporting(progress: 0)

        let destination = outputURL(for: key)
        let source = UncheckedSendable(composition)
        let volumes = volumes
        let clicks = clicks
        let annotations = annotations
        exportTask = Task {
            // Regroupe les modifications rapprochées en un seul export.
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }

            let temporary = destination.deletingLastPathComponent()
                .appending(path: ".\(UUID().uuidString).mp4")
            do {
                try await VideoExporter.export(
                    source.value, plan: plan, volumes: volumes, clicks: clicks, annotations: annotations, to: temporary
                ) { progress in
                    Task { @MainActor in
                        guard case .exporting = self.status else { return }
                        self.status = .exporting(progress: progress)
                    }
                }
                try Task.checkCancellation()
                // Remplacement en une fois : le fichier final n'est jamais à moitié écrit.
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: destination)
                }
                let bytes = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                cache[key] = (destination, bytes)
                if plan.estimatedBytes > 0, bytes > 0 {
                    estimateCorrection = Double(bytes) / Double(plan.estimatedBytes)
                }
                status = .ready(url: destination, bytes: bytes)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                if !Task.isCancelled {
                    status = .failed(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Partage

    var readyURL: URL? {
        Self.readyURL(of: status)
    }

    private static func readyURL(of status: Status) -> URL? {
        if case .ready(let url, _) = status { return url }
        return nil
    }

    /// Met le fichier dans le presse-papier comme le ferait "Copier" dans le Finder : il se colle dans Slack, Jira…
    func copyToPasteboard() {
        guard let url = readyURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        justCopied = true
        copiedTask?.cancel()
        copiedTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            justCopied = false
        }
    }

    func saveAs() {
        guard let url = readyURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = url.lastPathComponent
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            status = .failed(String(localized: "Couldn't save: \(error.localizedDescription)"))
        }
    }
}

/// Passe un objet AVFoundation immuable (une composition figée) à une tâche de fond.
struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
