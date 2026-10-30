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
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = recording.url.deletingPathExtension().lastPathComponent
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.contentView = NSHostingView(rootView: EditorView(document: document))
        window.delegate = self
        window.center()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Les moniteurs locaux sont appelés sur le thread principal.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated {
                guard let self, event.window === self.window else { return false }
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

    func windowWillClose(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        document.close()
        onClose?()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Lettres lues d'après le caractère tapé (AZERTY), touches spéciales d'après leur code.
        let character = event.charactersIgnoringModifiers?.lowercased()

        switch (Int(event.keyCode), character, modifiers) {
        case (kVK_Space, _, []):
            document.togglePlay()
        case (_, "x", []):
            document.cutAtPlayhead()
        case (kVK_Delete, _, []), (kVK_ForwardDelete, _, []):
            document.deleteSelectedSegment()
        case (kVK_LeftArrow, _, []):
            document.step(by: -EditorDocument.frameDuration)
        case (kVK_RightArrow, _, []):
            document.step(by: EditorDocument.frameDuration)
        case (kVK_LeftArrow, _, [.shift]):
            document.step(by: -1)
        case (kVK_RightArrow, _, [.shift]):
            document.step(by: 1)
        case (kVK_Home, _, []):
            document.seek(to: 0)
        case (kVK_End, _, []):
            document.seek(to: document.duration)
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
