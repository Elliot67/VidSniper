import SwiftUI

/// Onglet Export : le MP4 tel qu'il sera envoyé, ses réglages et le partage.
struct ExportTab: View {
    let document: EditorDocument

    private var export: ExportModel { document.export }

    var body: some View {
        VStack(spacing: 0) {
            ExportPreview(document: document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Theme.border)

            VStack(spacing: Theme.spacing) {
                playback
                ExportPanel(export: export, thumbnail: document.firstFrameThumbnail)
            }
            .padding(Theme.spacing * 1.5)
            .background(Theme.backgroundPrimary)
            .disabled(!document.isReady)
        }
    }

    private var playback: some View {
        HStack(spacing: Theme.spacing) {
            Button(action: document.togglePlay) {
                Image(systemName: document.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(IconButtonStyle())
            .focusable(false)
            .disabled(document.isShowingExport && export.readyURL == nil)

            Text(verbatim: "\(EditorView.format(document.currentTime)) / \(EditorView.format(document.duration))")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)

            Slider(
                value: Binding(get: { document.currentTime }, set: { document.seek(to: $0) }),
                in: 0...max(document.duration, 0.01)
            ) { isEditing in
                if isEditing, document.isPlaying { document.togglePlay() }
            }
            .controlSize(.small)
            .tint(Theme.accent)
            .focusable(false)
        }
    }
}

/// Outils de l'onglet Export, dans la barre du haut : comparer avec l'original, zoom.
struct ExportToolbar: View {
    let document: EditorDocument

    var body: some View {
        HStack(spacing: 8) {
            // À maintenir : relâcher revient au MP4.
            ChipLabel(isOn: document.showsOriginal, icon: "eye", title: String(localized: "Original"), shortcut: "⌥")
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in document.setShowsOriginal(true) }
                        .onEnded { _ in document.setShowsOriginal(false) }
                )
                .help("Hold to show the original, before compression (or hold ⌥)")

            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 18)

            Button { document.stepPreviewZoom(zoomIn: false) } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(IconButtonStyle())
            .help("Zoom out (⌘− or pinch)")

            Text(document.displayedPreviewZoom.formatted(.percent.precision(.fractionLength(0))))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .frame(minWidth: 40)

            Button { document.stepPreviewZoom(zoomIn: true) } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(IconButtonStyle())
            .help("Zoom in (⌘+ or pinch)")

            chip(isOn: document.previewZoom == nil, icon: "arrow.down.right.and.arrow.up.left", title: String(localized: "Fit")) {
                document.previewZoom = nil
            }
            .help("Show the whole video (⌘0)")

            chip(isOn: document.previewZoom == 1, icon: "1.magnifyingglass", title: String(localized: "Actual Size")) {
                document.setPreviewZoom(1)
            }
            .help("1 pixel of the video = 1 pixel of the screen, to check that text stays readable")
        }
        .focusable(false)
    }

    private func chip(isOn: Bool, icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ChipLabel(isOn: isOn, icon: icon, title: title)
        }
        .buttonStyle(.plain)
    }
}

/// Le MP4 exporté, ou le montage d'origine pendant l'appui sur "Original", au même endroit et à la même taille.
private struct ExportPreview: View {
    let document: EditorDocument
    @Environment(\.displayScale) private var displayScale

    private var export: ExportModel { document.export }

    /// Taille de la vidéo à 100 % : 1 pixel du MP4 = 1 pixel de l'écran.
    private var actualSize: CGSize {
        guard let plan = export.plan else { return .zero }
        return CGSize(width: CGFloat(plan.width) / displayScale, height: CGFloat(plan.height) / displayScale)
    }

    var body: some View {
        ZoomablePreview(
            contentSize: actualSize,
            zoom: document.previewZoom,
            range: EditorDocument.previewZoomRange,
            onFitZoomChange: { document.previewFitZoom = $0 },
            onPinch: { document.setPreviewZoom($0) }
        ) {
            players
        }
        .background(Color.black)
        .overlay(alignment: .topLeading) {
            badge.padding(10)
        }
        .overlay {
            if document.isShowingExport {
                status
            }
        }
    }

    private var players: some View {
        ZStack {
            PlayerLayerView(player: document.exportPlayer)
            PlayerLayerView(player: document.player)
                .overlay {
                    if document.isReady {
                        AnnotationLayer(document: document)
                            .allowsHitTesting(false)
                    }
                }
                .opacity(document.showsOriginal ? 1 : 0)
        }
    }

    /// Ce qui est affiché : le MP4 (avec sa définition) ou l'original.
    private var badge: some View {
        Group {
            if document.showsOriginal {
                Text("Original")
            } else if let plan = export.plan {
                Text(verbatim: "MP4 · \(plan.width) × \(plan.height)")
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(document.showsOriginal ? Theme.accent : Color.black.opacity(0.6))
        )
    }

    @ViewBuilder
    private var status: some View {
        switch export.status {
        case .exporting(let progress):
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .frame(width: 160)
                Text("Exporting…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        case .failed(let message):
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Theme.error)
                .padding()
        case .waiting, .ready:
            EmptyView()
        }
    }
}
