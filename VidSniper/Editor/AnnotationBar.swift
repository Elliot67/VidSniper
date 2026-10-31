import SwiftUI

/// Barre "Annoter" au-dessus de la vidéo : l'outil "Tracer", puis le rendu de l'annotation (cadre ou
/// projecteur, rectangle ou ellipse, couleur) et sa suppression. Une annotation est un seul élément :
/// style, forme et couleur ne changent que son rendu. Ils s'appliquent à l'annotation sélectionnée,
/// sinon aux prochaines.
struct AnnotationBar: View {
    let document: EditorDocument

    private var targetStyle: AnnotationStyle {
        document.selectedAnnotation?.style ?? document.newAnnotationStyle
    }

    private var targetShape: AnnotationShape {
        document.selectedAnnotation?.shape ?? document.newAnnotationShape
    }

    private var targetColor: AnnotationColor {
        document.selectedAnnotation?.color ?? document.newAnnotationColor
    }

    /// Un projecteur n'a pas de couleur : il assombrit simplement le reste de l'image.
    private var colorApplies: Bool {
        targetStyle == .frame
    }

    var body: some View {
        HStack(spacing: 8) {
            ToggleChip(
                isOn: Binding(get: { document.isDrawingAnnotation }, set: { _ in document.toggleAnnotationDrawing() }),
                title: "Tracer",
                onIcon: "pencil.tip",
                offIcon: "pencil.tip"
            )
            .help("Tracer une annotation : glisser sur la vidéo")

            separator

            optionButton(
                isSelected: targetStyle == .frame,
                icon: "rectangle.dashed",
                title: "Cadre",
                help: "Rendu : contour coloré autour de la zone"
            ) {
                document.setAnnotationStyle(.frame)
            }
            optionButton(
                isSelected: targetStyle == .spotlight,
                icon: "light.max",
                title: "Projecteur",
                help: "Rendu : tout est assombri sauf la zone"
            ) {
                document.setAnnotationStyle(.spotlight)
            }

            separator

            optionButton(isSelected: targetShape == .rectangle, icon: "rectangle", title: nil, help: "Rectangle arrondi") {
                document.setAnnotationShape(.rectangle)
            }
            optionButton(isSelected: targetShape == .ellipse, icon: "circle", title: nil, help: "Ellipse") {
                document.setAnnotationShape(.ellipse)
            }

            separator

            HStack(spacing: 6) {
                ForEach(AnnotationColor.allCases) { color in
                    ColorSwatch(color: color, isSelected: colorApplies && targetColor == color) {
                        document.setAnnotationColor(color)
                    }
                }
            }
            .disabled(!colorApplies)
            .opacity(colorApplies ? 1 : 0.35)
            .help(colorApplies ? "Couleur du cadre" : "Un projecteur n'a pas de couleur")

            separator

            Button(action: document.deleteSelectedAnnotation) {
                Image(systemName: "trash")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(document.selectedAnnotationID == nil)
            .help("Supprimer l'annotation sélectionnée (⌫)")

            Spacer(minLength: 0)

            // Tous les raccourcis, au survol.
            ShortcutsHelp()
        }
        .focusable(false)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 18)
    }

    /// Option de rendu (style ou forme), surlignée quand c'est celle de la cible.
    private func optionButton(
        isSelected: Bool,
        icon: String,
        title: String?,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .frame(width: 16, height: 14)
                if let title {
                    Text(title)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isSelected ? Theme.accent : Theme.textMuted)
            .padding(.horizontal, title == nil ? 5 : 9)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(isSelected ? Theme.accent.opacity(0.12) : Theme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(isSelected ? Theme.accent.opacity(0.5) : Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Pastille de couleur cliquable (annotations, clics).
struct ColorSwatch: View {
    let color: AnnotationColor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color.color)
                .frame(width: 14, height: 14)
                .padding(3)
                .overlay(
                    Circle().stroke(isSelected ? Theme.textNormal : Color.clear, lineWidth: 1.5)
                )
        }
        .buttonStyle(.plain)
        .help(color.label)
    }
}
