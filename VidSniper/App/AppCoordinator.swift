import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

/// Orchestration du déroulé : sélection de zone → enregistrement → résultat.
@MainActor
@Observable
final class AppCoordinator {
    enum State {
        case idle, selecting, starting, recording, finishing
    }

    private(set) var state: State = .idle
    private(set) var lastRecording: RecordingResult?
    private(set) var lastError: String?

    let permissions = Permissions()
    let launchAtLogin = LaunchAtLogin()
    let options = SelectionOptions()
    let session = RecordingSession()

    @ObservationIgnored private var hotKey: HotKey?
    @ObservationIgnored private let mainWindow = MainWindowController()
    @ObservationIgnored private var overlay: SelectionOverlay?
    @ObservationIgnored private var recorder: Recorder?
    @ObservationIgnored private var recordingBar: RecordingBarController?
    @ObservationIgnored private var editors: [EditorWindowController] = []
    @ObservationIgnored private var clickMonitor: Any?
    @ObservationIgnored private var clicks: [ClickMark] = []
    /// Zone en cours d'enregistrement (elle peut être déplacée), pour situer les clics.
    @ObservationIgnored private var trackedRegion: CaptureRegion?

    // MARK: - Raccourci global

    private(set) var shortcut = Shortcut.saved
    private(set) var isRecordingShortcut = false
    private(set) var shortcutMessage: String?
    @ObservationIgnored private var shortcutMonitor: Any?

    /// Libellé du raccourci, pour les vues qui n'ont pas accès au coordinateur (mini barre).
    static var shortcutLabel: String { Shortcut.saved.label }

    init() {
        let hotKey = HotKey { [weak self] in self?.handleHotKey() }
        if !hotKey.register(shortcut) {
            lastError = "Le raccourci \(shortcut.label) est déjà utilisé par une autre app : choisis-en un autre."
        }
        self.hotKey = hotKey
    }

    /// Écoute le prochain raccourci tapé dans l'app. Le raccourci actuel est suspendu pendant ce temps,
    /// pour pouvoir le retaper sans lancer une capture. Esc annule.
    func beginShortcutRecording() {
        guard !isRecordingShortcut else { return }
        isRecordingShortcut = true
        shortcutMessage = nil
        hotKey?.unregister()
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Les moniteurs locaux sont appelés sur le thread principal.
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { self?.recordShortcut(from: event) }
            return nil
        }
    }

    func endShortcutRecording() {
        guard isRecordingShortcut else { return }
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        isRecordingShortcut = false
        hotKey?.register(shortcut)
    }

    private func recordShortcut(from event: NSEvent) {
        if Int(event.keyCode) == kVK_Escape {
            endShortcutRecording()
            return
        }
        guard let newShortcut = Shortcut(event: event) else {
            shortcutMessage = "Il faut au moins ⌘, ⌥ ou ⌃ avec la touche."
            return
        }
        endShortcutRecording()
        setShortcut(newShortcut)
    }

    func setShortcut(_ newShortcut: Shortcut) {
        guard let hotKey else { return }
        if hotKey.register(newShortcut) {
            shortcut = newShortcut
            Shortcut.saved = newShortcut
            shortcutMessage = nil
            if lastError?.contains("raccourci") == true { lastError = nil }
        } else {
            hotKey.register(shortcut)
            shortcutMessage = "\(newShortcut.label) est déjà utilisé par une autre app."
        }
    }

    func showMainWindow() {
        mainWindow.show(
            MainView()
                .environment(self)
                .environment(permissions)
        )
    }

    private func handleHotKey() {
        switch state {
        case .idle: startSelection()
        case .selecting: cancelSelection()
        case .recording: stopRecording()
        case .starting, .finishing: break
        }
    }

    // MARK: - Sélection

    func startSelection() {
        guard state == .idle else { return }
        permissions.refresh()
        guard permissions.screenRecording else {
            lastError = "La permission d'enregistrement de l'écran est nécessaire."
            showMainWindow()
            return
        }
        lastError = nil
        state = .selecting
        mainWindow.hide()

        let overlay = SelectionOverlay(
            options: options,
            microphoneAvailable: permissions.microphone == .authorized,
            onConfirm: { [weak self] region in self?.startRecording(region) },
            onCancel: { [weak self] in self?.cancelSelection() }
        )
        overlay.show(initial: CaptureRegion.last)
        self.overlay = overlay
    }

    private func cancelSelection() {
        overlay?.close()
        overlay = nil
        state = .idle
        showMainWindow()
    }

    // MARK: - Enregistrement

    private func startRecording(_ region: CaptureRegion) {
        overlay?.close()
        overlay = nil
        state = .starting
        CaptureRegion.last = region

        let captureOptions = CaptureOptions(
            microphone: options.microphone && permissions.microphone == .authorized,
            systemAudio: options.systemAudio
        )
        let recorder = Recorder(outputURL: RecordingStore.newRecordingURL())
        recorder.onInterrupted = { [weak self] error in
            Task { @MainActor in
                self?.lastError = error.localizedDescription
                self?.stopRecording()
            }
        }

        Task {
            do {
                try await recorder.start(region: region, options: captureOptions)
                self.recorder = recorder
                session.start()
                state = .recording
                let bar = RecordingBarController(
                    region: region,
                    session: session,
                    onTogglePause: { self.togglePause() },
                    onStop: { self.stopRecording() },
                    onMove: { region in
                        recorder.move(to: region.rect)
                        CaptureRegion.last = region
                        self.trackedRegion = region
                    }
                )
                bar.show()
                recordingBar = bar
                startClickTracking(region: region)
            } catch {
                lastError = "Impossible de démarrer l'enregistrement : \(error.localizedDescription)"
                state = .idle
                showMainWindow()
            }
        }
    }

    private func togglePause() {
        guard state == .recording, let recorder else { return }
        if session.isPaused {
            recorder.resume()
            session.resume()
        } else {
            recorder.pause()
            session.pause()
        }
    }

    // MARK: - Clics

    /// Écoute les clics dans les autres apps pendant l'enregistrement (pas de permission nécessaire pour la souris).
    /// Les clics sur la mini barre de VidSniper sont des événements locaux : ils ne sont pas comptés.
    private func startClickTracking(region: CaptureRegion) {
        clicks = []
        trackedRegion = region
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordClick() }
        }
    }

    private func stopClickTracking() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    private func recordClick() {
        guard let recorder, let region = trackedRegion, let screen = region.screen,
              let time = recorder.currentRecordingTime()
        else { return }
        let rect = region.globalRect(on: screen)
        let location = NSEvent.mouseLocation
        guard rect.contains(location), rect.width > 0, rect.height > 0 else { return }
        clicks.append(ClickMark(
            time: time,
            x: (location.x - rect.minX) / rect.width,
            y: (rect.maxY - location.y) / rect.height
        ))
    }

    func stopRecording() {
        guard state == .recording, let recorder else { return }
        state = .finishing
        stopClickTracking()
        recordingBar?.close()
        recordingBar = nil
        // Activation tout de suite, pendant que macOS considère encore l'action (clic ou raccourci) comme récente :
        // l'éditeur, ouvert après la finalisation du fichier, passe ainsi au premier plan.
        NSApp.activate()

        Task {
            do {
                var recording = try await recorder.stop()
                recording.clicks = clicks
                lastRecording = recording
                self.recorder = nil
                state = .idle
                openEditor(recording)
            } catch {
                lastError = "L'enregistrement a échoué : \(error.localizedDescription)"
                self.recorder = nil
                state = .idle
                showMainWindow()
            }
        }
    }

    // MARK: - Import

    /// Choix d'une vidéo existante à éditer (bouton, ⌘O).
    func importVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = VideoImporter.contentTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choisis une vidéo à éditer"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVideo(at: url)
    }

    /// Ouvre une vidéo existante dans l'éditeur (import, glisser-déposer, "Ouvrir avec" depuis le Finder).
    func openVideo(at url: URL) {
        Task {
            do {
                let video = try await VideoImporter.inspect(url)
                lastError = nil
                lastRecording = video
                openEditor(video)
            } catch {
                lastError = error.localizedDescription
                showMainWindow()
            }
        }
    }

    // MARK: - Éditeur

    func openEditor(_ recording: RecordingResult) {
        if let existing = editors.first(where: { $0.document.recording.url == recording.url }) {
            existing.show()
            return
        }
        let editor = EditorWindowController(recording: recording)
        editor.onClose = { [weak self, weak editor] in
            self?.editors.removeAll { $0 === editor }
        }
        editors.append(editor)
        editor.show()
    }
}

/// Fenêtre principale en AppKit, pour pouvoir la masquer pendant la capture et la rouvrir depuis le Dock.
@MainActor
final class MainWindowController {
    private var window: NSWindow?

    func show<Content: View>(_ content: @autoclosure () -> Content) {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "VidSniper"
            window.isReleasedWhenClosed = false
            window.contentMinSize = NSSize(width: 420, height: 320)
            window.contentView = NSHostingView(rootView: content())
            window.center()
            window.setFrameAutosaveName("MainWindow")
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func hide() {
        window?.orderOut(nil)
    }
}
