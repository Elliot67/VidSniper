import SwiftUI

/// Petit "?" en haut à droite de l'éditeur : au survol, la liste de tous les raccourcis,
/// un par ligne, regroupés par catégorie.
struct ShortcutsHelp: View {
    @State private var isShown = false

    private struct Shortcut: Identifiable {
        let keys: String
        let action: String
        var id: String { keys + action }
    }

    private struct Category: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    private var categories: [Category] {
        [
            Category(title: "Lecture", shortcuts: [
                Shortcut(keys: "Espace", action: "Lecture / pause"),
                Shortcut(keys: "← →", action: "Image précédente / suivante"),
                Shortcut(keys: "⇧← ⇧→", action: "Reculer / avancer d'une seconde"),
                Shortcut(keys: "Début / Fin", action: "Aller au début / à la fin"),
            ]),
            Category(title: "Montage", shortcuts: [
                Shortcut(keys: "X", action: "Couper à la tête de lecture"),
                Shortcut(keys: "⌫", action: "Supprimer le segment ou l'annotation sélectionné"),
                Shortcut(keys: "⌘Z", action: "Annuler"),
                Shortcut(keys: "⇧⌘Z", action: "Rétablir"),
            ]),
            Category(title: "Annotations", shortcuts: [
                Shortcut(keys: "Glisser", action: "Tracer (outil Tracer actif)"),
                Shortcut(keys: "Coins", action: "Redimensionner l'annotation sélectionnée"),
                Shortcut(keys: "Esc", action: "Arrêter le tracé, puis désélectionner"),
            ]),
            Category(title: "Timeline", shortcuts: [
                Shortcut(keys: "⌘+ / ⌘−", action: "Zoomer / dézoomer"),
                Shortcut(keys: "Pincer", action: "Zoomer autour du pointeur"),
                Shortcut(keys: "Glisser ↕", action: "Défiler (deux doigts)"),
            ]),
            Category(title: "Export", shortcuts: [
                Shortcut(keys: "⌘C", action: "Copier la vidéo"),
                Shortcut(keys: "⌘S", action: "Enregistrer une copie"),
            ]),
            Category(title: "Partout", shortcuts: [
                Shortcut(keys: AppCoordinator.shortcutLabel, action: "Nouvel enregistrement / arrêter"),
                Shortcut(keys: "⌘O", action: "Importer une vidéo"),
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
            ForEach(categories) { category in
                VStack(alignment: .leading, spacing: 4) {
                    Text(category.title.uppercased())
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
