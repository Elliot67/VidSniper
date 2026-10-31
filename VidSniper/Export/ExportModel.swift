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

    var size: ExportSize {
        didSet {
            UserDefaults.standard.set(size.rawValue, forKey: "exportSize")
            scheduleExport()
        }
    }

    var quality: ExportQuality {
        didSet {
            UserDefaults.standard.set(quality.rawValue, forKey: "exportQuality")
            scheduleExport()
        }
    }

    private(set) var status: Status = .waiting
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
    /// Le nom du fichier est celui que verront les destinataires (Slack, Jira…).
    @ObservationIgnored private let fileName: String
    /// Exports déjà faits pendant la session : revenir à un réglage déjà essayé est instantané.
    @ObservationIgnored private var cache: [String: (url: URL, bytes: Int64)] = [:]

    init(recording: RecordingResult) {
        let defaults = UserDefaults.standard
        size = ExportSize(rawValue: defaults.double(forKey: "exportSize")) ?? .full
        quality = ExportQuality(rawValue: defaults.string(forKey: "exportQuality") ?? "") ?? .medium
        fileName = recording.url.deletingPathExtension().lastPathComponent + ".mp4"
    }

    private var cacheKey: String {
        let volumes = volumes.map { "\($0.trackID):\($0.volume)" }.joined(separator: ",")
        return "\(signature)|\(size.rawValue)|\(quality.rawValue)|\(volumes)"
    }

    /// Chaque export a son propre dossier, pour garder le même nom de fichier dans tous les cas.
    private func outputURL(for key: String) -> URL {
        let folder = RecordingStore.exportsDirectory
            .appending(path: String(UInt(bitPattern: key.hashValue), radix: 16), directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: fileName)
    }

    var plan: ExportPlan? {
        guard videoSize != .zero, duration > 0 else { return nil }
        return ExportPlan(sourceSize: videoSize, duration: duration, hasAudio: hasAudio, size: size, quality: quality)
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

    func cancel() {
        exportTask?.cancel()
        exportTask = nil
    }

    private func scheduleExport() {
        exportTask?.cancel()
        guard let composition, let plan else { return }
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
