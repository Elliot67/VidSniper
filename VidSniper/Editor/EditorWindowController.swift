import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Fenêtre de l'éditeur. Les raccourcis sont interceptés au niveau de la fenêtre (moniteur local),
/// avant les vues, pour marcher quel que soit l'élément qui a le focus.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    let document: EditorDocument
    var onClose: (() -> Void)?

    private let window: NSWindow
    private var keyMonitor: Any?

    init(recording: RecordingResult) {
        document = EditorDocument(recording: recording)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 860),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = recording.url.deletingPathExtension().lastPathComponent
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 900, height: 720)
        window.contentView = NSHostingView(rootView: EditorView(document: document))
        window.delegate = self
        window.center()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            // Les moniteurs locaux sont appelés sur le thread principal.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
                if event.type == .flagsChanged {
                    // ⌥ maintenu : l'original à la place du MP4, dans l'onglet Export.
                    self.document.setShowsOriginal(event.modifierFlags.contains(.option))
                    return false
                }
                return self.handleKey(event)
            }
            return handled ? nil : event
        }

        Task { await document.load() }
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// ⌥ relâché hors de la fenêtre : on ne resterait pas bloqué sur l'original.
    func windowDidResignKey(_ notification: Notification) {
        document.setShowsOriginal(false)
    }

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        document.close()
        onClose?()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Lettres lues d'après le caractère tapé (AZERTY), touches spéciales et chiffres d'après leur code
        // (en AZERTY, la touche 1 donne "&").
        let character = event.charactersIgnoringModifiers?.lowercased()

        switch (Int(event.keyCode), character, modifiers) {
        case (kVK_ANSI_1, _, [.command]):
            document.selectTab(.edit)
        case (kVK_ANSI_2, _, [.command]):
            document.selectTab(.export)
        case (_, "c", [.command]):
            document.export.copyToPasteboard()
        case (_, "s", [.command]):
            document.export.saveAs()
        default:
            return handlePlaybackKey(event, character: character, modifiers: modifiers)
        }
        return true
    }

    /// Lecture : dans les deux onglets. Le reste (montage, annotations, zoom de la timeline) : onglet Édition.
    private func handlePlaybackKey(_ event: NSEvent, character: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch (Int(event.keyCode), modifiers) {
        case (kVK_Space, []):
            document.togglePlay()
        case (kVK_LeftArrow, []):
            document.step(by: -EditorDocument.frameDuration)
        case (kVK_RightArrow, []):
            document.step(by: EditorDocument.frameDuration)
        case (kVK_LeftArrow, [.shift]):
            document.step(by: -1)
        case (kVK_RightArrow, [.shift]):
            document.step(by: 1)
        case (kVK_Home, []):
            document.seek(to: 0)
        case (kVK_End, []):
            document.seek(to: document.duration)
        default:
            switch document.tab {
            case .edit: return handleEditKey(event, character: character, modifiers: modifiers)
            case .export: return handleExportKey(character: character, modifiers: modifiers)
            }
        }
        return true
    }

    /// Zoom de la vidéo exportée.
    private func handleExportKey(character: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch (character, modifiers) {
        case ("+", [.command]), ("=", [.command]), ("+", [.command, .shift]), ("=", [.command, .shift]):
            document.stepPreviewZoom(zoomIn: true)
        case ("-", [.command]):
            document.stepPreviewZoom(zoomIn: false)
        case ("0", [.command]), ("à", [.command]):
            document.previewZoom = nil
        default:
            return false
        }
        return true
    }

    private func handleEditKey(_ event: NSEvent, character: String?, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch (Int(event.keyCode), character, modifiers) {
        case (_, "x", []):
            document.cutAtPlayhead()
        case (kVK_Delete, _, []), (kVK_ForwardDelete, _, []):
            // L'annotation sélectionnée passe avant le segment.
            if document.selectedAnnotationID != nil {
                document.deleteSelectedAnnotation()
            } else {
                document.deleteSelectedSegment()
            }
        case (kVK_Escape, _, []):
            document.cancelAnnotationInteraction()
        case (_, "z", [.command]):
            document.undo()
        case (_, "z", [.command, .shift]):
            document.redo()
        case (_, "+", [.command]), (_, "=", [.command]), (_, "+", [.command, .shift]), (_, "=", [.command, .shift]):
            document.zoom(by: 1.5)
        case (_, "-", [.command]):
            document.zoom(by: 1 / 1.5)
        default:
            return false
        }
        return true
    }
}
