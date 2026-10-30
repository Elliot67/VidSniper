import SwiftUI

struct EditorView: View {
    let document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: document.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    // Aperçu d'une image hors montage, quand on rallonge un clip.
                    if let frame = document.trimPreviewFrame {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.black)
                    }
                }
                .overlay {
                    if let error = document.loadError {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.error)
                    } else if !document.isReady {
                        ProgressView().controlSize(.small)
                    }
                }

            Divider().overlay(Theme.border)

            VStack(spacing: Theme.spacing) {
                controls
                EditorTimeline(document: document)
                shortcutsHint
                ExportBar(export: document.export, thumbnail: document.firstFrameThumbnail)
            }
            .padding(Theme.spacing * 1.5)
            .background(Theme.backgroundPrimary)
            .disabled(!document.isReady)
        }
        .background(Theme.backgroundPrimary)
    }

    private var controls: some View {
        HStack(spacing: Theme.spacing) {
            Button(action: document.togglePlay) {
                Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)

            Text("\(Self.format(document.currentTime)) / \(Self.format(document.duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)

            Spacer()

            Button(action: document.cutAtPlayhead) {
                Label("Couper", systemImage: "scissors")
            }
            .buttonStyle(SecondaryButtonStyle())
            .focusable(false)
            .help("Couper à la tête de lecture (X)")

            Button(action: document.deleteSelectedSegment) {
                Label("Supprimer", systemImage: "trash")
            }
            .buttonStyle(SecondaryButtonStyle())
            .focusable(false)
            .disabled(document.selectedSegment == nil || document.state.segments.count < 2)
            .help("Supprimer le segment sélectionné (⌫)")

            Button(action: document.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .disabled(!document.canUndo)
            .help("Annuler (⌘Z)")

            Button(action: document.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .disabled(!document.canRedo)
            .help("Rétablir (⌘⇧Z)")

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 20)

            Button { document.zoom(by: 1 / 1.5) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .disabled(document.scale <= document.fitScale + 0.001)
            .help("Dézoomer (⌘−)")

            Button { document.zoom(by: 1.5) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .help("Zoomer (⌘+)")

            Button("Ajuster", action: document.zoomToFit)
                .buttonStyle(SecondaryButtonStyle())
                .focusable(false)
                .help("Afficher tout le montage")
        }
    }

    private var shortcutsHint: some View {
        Text("Espace lecture · X couper · ⌫ supprimer le segment · ← → image par image (⇧ 1 s) · ⌘Z annuler · ⌘+ ⌘− zoom · ⌘C copier · ⌘S enregistrer")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func format(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}
