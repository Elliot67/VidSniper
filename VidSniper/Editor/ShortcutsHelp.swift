import SwiftUI

/// Petit "?" en haut à droite de l'éditeur : au survol, la liste de tous les raccourcis,
/// un par ligne, regroupés par catégorie.
struct ShortcutsHelp: View {
    @State private var isShown = false

    private struct Shortcut: Identifiable {
        let keys: String
        let action: LocalizedStringKey
        var id: String { keys }
    }

    private struct Category {
        let title: LocalizedStringKey
        let shortcuts: [Shortcut]
    }

    private var categories: [Category] {
        [
            Category(title: "Playback", shortcuts: [
                Shortcut(keys: String(localized: "Space"), action: "Play / pause"),
                Shortcut(keys: "← →", action: "Previous / next frame"),
                Shortcut(keys: "⇧← ⇧→", action: "Back / forward one second"),
                Shortcut(keys: String(localized: "Home / End"), action: "Go to start / end"),
            ]),
            Category(title: "Editing", shortcuts: [
                Shortcut(keys: "X", action: "Split at the playhead"),
                Shortcut(keys: "⌫", action: "Delete the selected segment or annotation"),
                Shortcut(keys: "⌘Z", action: "Undo"),
                Shortcut(keys: "⇧⌘Z", action: "Redo"),
            ]),
            Category(title: "Annotations", shortcuts: [
                Shortcut(keys: String(localized: "Drag"), action: "Draw (Draw tool on)"),
                Shortcut(keys: String(localized: "Corners"), action: "Resize the selected annotation"),
                Shortcut(keys: "Esc", action: "Stop drawing, then deselect"),
            ]),
            Category(title: "Timeline", shortcuts: [
                Shortcut(keys: "⌘+ / ⌘−", action: "Zoom in / out"),
                Shortcut(keys: String(localized: "Pinch"), action: "Zoom around the pointer"),
                Shortcut(keys: String(localized: "Drag ↕"), action: "Scroll (two fingers)"),
            ]),
            Category(title: "Export", shortcuts: [
                Shortcut(keys: "⌘1 / ⌘2", action: "Edit / Export tab"),
                Shortcut(keys: String(localized: "Hold ⌥"), action: "Show the original (Export tab)"),
                Shortcut(keys: "⌘+ / ⌘− / ⌘0", action: "Zoom the video / fit (Export tab)"),
                Shortcut(keys: "⌘C", action: "Copy the video"),
                Shortcut(keys: "⌘S", action: "Save a copy"),
            ]),
            Category(title: "Anywhere", shortcuts: [
                Shortcut(keys: AppCoordinator.shortcutLabel, action: "New recording / stop"),
                Shortcut(keys: "⌘O", action: "Import Video"),
            ]),
        ]
    }

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 14))
            .foregroundStyle(isShown ? Theme.accent : Theme.textMuted)
            .frame(width: 24, height: 24)
            .contentShape(Rectangle())
            .onHover { isShown = $0 }
            .popover(isPresented: $isShown, arrowEdge: .bottom) {
                list
            }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(categories.enumerated()), id: \.offset) { _, category in
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title)
                        .textCase(.uppercase)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textMuted)
                    ForEach(category.shortcuts) { shortcut in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(shortcut.keys)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.textNormal)
                                .frame(width: 92, alignment: .leading)
                            Text(shortcut.action)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textNormal)
                        }
                    }
                }
            }
        }
        .padding(14)
        .fixedSize()
    }
}
