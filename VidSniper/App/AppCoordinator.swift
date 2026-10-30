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

    static let shortcutLabel = "⌘⇧8"

    init() {
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.handleHotKey()
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
                    }
                )
                bar.show()
                recordingBar = bar
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

    func stopRecording() {
        guard state == .recording, let recorder else { return }
        state = .finishing
        recordingBar?.close()
        recordingBar = nil
        // Activation tout de suite, pendant que macOS considère encore l'action (clic ou raccourci) comme récente :
        // l'éditeur, ouvert après la finalisation du fichier, passe ainsi au premier plan.
        NSApp.activate()

        Task {
            do {
                let recording = try await recorder.stop()
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
