import AppKit
import Carbon.HIToolbox

/// Raccourci global : touche + modificateurs Carbon, et son libellé (ex. "⇧⌘8"). Mémorisé dans les préférences.
struct Shortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(cmdKey | shiftKey), label: "⇧⌘8")

    private static let defaultsKey = "globalShortcut"

    static var saved: Shortcut {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey),
                  let shortcut = try? JSONDecoder().decode(Shortcut.self, from: data)
            else { return .standard }
            return shortcut
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
        }
    }

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    /// Raccourci tapé au clavier. Il faut au moins ⌘, ⌥ ou ⌃ : une touche seule gênerait la frappe partout.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty,
              let key = Self.keyName(for: event, shift: flags.contains(.shift))
        else { return nil }

        var modifiers = 0
        var label = ""
        // Ordre habituel des symboles sur macOS : ⌃⌥⇧⌘.
        if flags.contains(.control) { modifiers |= controlKey; label += "⌃" }
        if flags.contains(.option) { modifiers |= optionKey; label += "⌥" }
        if flags.contains(.shift) { modifiers |= shiftKey; label += "⇧" }
        if flags.contains(.command) { modifiers |= cmdKey; label += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), modifiers: UInt32(modifiers), label: label + key)
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: String(localized: "Space"), kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// Nom de la touche tel qu'imprimé sur le clavier (AZERTY compris : avec ⇧, la touche "8" donne bien "8").
    private static func keyName(for event: NSEvent, shift: Bool) -> String? {
        if let special = specialKeys[Int(event.keyCode)] { return special }
        guard let characters = event.characters(byApplyingModifiers: shift ? [.shift] : []),
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar)
        else { return nil }
        return characters.uppercased()
    }
}

/// Raccourci clavier global via Carbon : marche app en arrière-plan, sans permission Accessibilité.
@MainActor
final class HotKey {
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            // Les événements Carbon arrivent sur le thread principal.
            MainActor.assumeIsolated {
                Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &eventType, userData, &handlerRef)
    }

    /// Enregistre le raccourci (en remplaçant le précédent). Faux s'il est déjà pris par une autre app.
    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5653_4E50), id: 1) // "VSNP"
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef
        )
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }
}
