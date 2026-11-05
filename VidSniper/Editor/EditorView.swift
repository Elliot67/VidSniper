import SwiftUI

/// Éditeur en deux onglets : Édition (annotations, montage) et Export (MP4 obtenu, réglages, partage).
struct EditorView: View {
    let document: EditorDocument

    var body: some View {
        VStack(spacing: 0) {
            EditorTabBar(document: document)

            toolbar

            Divider().overlay(Theme.border)

            switch document.tab {
            case .edit:
                editTab
            case .export:
                ExportTab(document: document)
            }
        }
        .background(Theme.backgroundPrimary)
        // Confirmation de copie (bouton ou ⌘C), quel que soit l'onglet.
        .overlay(alignment: .top) {
            if document.export.justCopied {
                CopiedToast()
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: document.export.justCopied)
    }

    /// Outils de l'onglet, et l'aide des raccourcis à droite.
    private var toolbar: some View {
        HStack(spacing: 8) {
            switch document.tab {
            case .edit:
                // Outils d'annotation au-dessus de la vidéo, sur laquelle on trace.
                AnnotationBar(document: document)
                    .disabled(!document.isReady)
            case .export:
                ExportToolbar(document: document)
                    .disabled(!document.isReady)
            }

            Spacer(minLength: 0)

            // Tous les raccourcis, au survol.
            ShortcutsHelp()
        }
        .frame(height: 28)
        .padding(.horizontal, Theme.spacing * 1.5)
        .padding(.vertical, Theme.spacing * 0.75)
        .background(Theme.backgroundPrimary)
        .focusable(false)
    }

    private var editTab: some View {
        VStack(spacing: 0) {
            PlayerLayerView(player: document.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay {
                    if document.isReady {
                        AnnotationLayer(document: document)
                    }
                }
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
            }
            .padding(Theme.spacing * 1.5)
            .background(Theme.backgroundPrimary)
            .disabled(!document.isReady)
        }
    }

    private var controls: some View {
        HStack(spacing: Theme.spacing) {
            Button(action: document.togglePlay) {
                Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)

            Text(verbatim: "\(Self.format(document.currentTime)) / \(Self.format(document.duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)

            Spacer()

            Button(action: document.cutAtPlayhead) {
                Label("Split", systemImage: "scissors")
            }
            .buttonStyle(SecondaryButtonStyle())
            .focusable(false)
            .help("Split at the playhead (X)")

            Button(action: document.deleteSelectedSegment) {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(SecondaryButtonStyle())
            .focusable(false)
            .disabled(document.selectedSegment == nil || document.state.segments.count < 2)
            .help("Delete the selected segment (⌫)")

            Button(action: document.undo) {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .disabled(!document.canUndo)
            .help("Undo (⌘Z)")

            Button(action: document.redo) {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .disabled(!document.canRedo)
            .help("Redo (⌘⇧Z)")

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 20)

            Button { document.zoom(by: 1 / 1.5) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .disabled(document.scale <= document.fitScale + 0.001)
            .help("Zoom out (⌘−)")

            Button { document.zoom(by: 1.5) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .help("Zoom in (⌘+)")

            Button("Fit", action: document.zoomToFit)
                .buttonStyle(SecondaryButtonStyle())
                .focusable(false)
                .help("Show the whole edit")
        }
    }

    static func format(_ seconds: Double) -> String {
        let tenths = Int((max(seconds, 0) * 10).rounded(.down))
        return String(format: "%d:%02d.%d", tenths / 600, (tenths / 10) % 60, tenths % 10)
    }
}

/// "Vidéo copiée", quelques secondes au-dessus de la vidéo.
private struct CopiedToast: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
            Text("Video copied")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textNormal)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius + 4)
                .fill(Theme.backgroundSecondary)
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius + 4)
                .stroke(Theme.border, lineWidth: 1)
        )
        .allowsHitTesting(false)
    }
}

/// Deux grands onglets sur toute la largeur (⌘1 / ⌘2) : l'onglet affiché teinté d'accent et souligné,
/// l'autre en retrait sur le fond de la fenêtre.
private struct EditorTabBar: View {
    let document: EditorDocument

    var body: some View {
        HStack(spacing: 0) {
            item(.edit, title: "Edit", icon: "scissors", shortcut: "⌘1", help: "Cuts, audio and annotations (⌘1)")
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1)
                .padding(.vertical, 8)
            item(.export, title: "Export", icon: "square.and.arrow.up", shortcut: "⌘2", help: "Check the exported video and share it (⌘2)")
        }
        .frame(height: 40)
        .background(Theme.backgroundPrimary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private func item(_ tab: EditorTab, title: LocalizedStringKey, icon: String, shortcut: String, help: LocalizedStringKey) -> some View {
        let isSelected = document.tab == tab
        return Button {
            document.selectTab(tab)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                Text(title)
                KeyCap(shortcut)
                    .foregroundStyle(Theme.textMuted)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Theme.accent : Theme.textMuted)
            .opacity(isSelected ? 1 : 0.8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isSelected ? Theme.accent.opacity(0.14) : Color.clear)
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle().fill(Theme.accent).frame(height: 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }
}
