import SwiftUI

/// Panneau d'export de l'éditeur : taille, qualité, poids, et la vidéo prête à glisser ou copier.
struct ExportBar: View {
    let export: ExportModel
    let thumbnail: CGImage?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spacing * 1.5) {
            VStack(alignment: .leading, spacing: 6) {
                optionRow("Taille") {
                    ForEach(ExportSize.allCases) { size in
                        ChoiceChip(title: size.label, isSelected: export.size == size) {
                            export.size = size
                        }
                    }
                }
                optionRow("Qualité") {
                    ForEach(ExportQuality.allCases) { quality in
                        ChoiceChip(title: quality.label, isSelected: export.quality == quality) {
                            export.quality = quality
                        }
                    }
                }
            }
            .focusable(false)

            summary

            Spacer(minLength: 0)

            dragTile

            VStack(alignment: .leading, spacing: 6) {
                Button {
                    export.copyToPasteboard()
                } label: {
                    HStack(spacing: 6) {
                        // Cadre fixe : la coche n'a ni la largeur ni la hauteur de l'icône de copie.
                        Image(systemName: export.justCopied ? "checkmark" : "doc.on.doc")
                            .frame(width: 16, height: 14)
                        Text(export.justCopied ? "Copiée" : "Copier")
                    }
                    .frame(minWidth: 96, alignment: .leading)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(export.readyURL == nil)
                .help("Copier la vidéo pour la coller dans Slack, Jira… (⌘C)")

                Button {
                    export.saveAs()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .frame(width: 16, height: 14)
                        Text("Enregistrer…")
                    }
                    .frame(minWidth: 96, alignment: .leading)
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(export.readyURL == nil)
                .help("Enregistrer une copie de la vidéo (⌘S)")
            }
            .focusable(false)
        }
        .padding(Theme.spacing)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
    }

    private func optionRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 48, alignment: .leading)
            content()
        }
    }

    // MARK: - Résumé

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let plan = export.plan {
                Text("\(plan.width) × \(plan.height) · MP4")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textNormal)
            }
            Text(sizeText)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textMuted)
            if case .failed(let message) = export.status {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.error)
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .leading)
            }
        }
    }

    private var sizeText: String {
        switch export.status {
        case .ready(_, let bytes):
            return "Poids : \(Self.format(bytes))"
        default:
            guard let plan = export.plan else { return "" }
            return "Estimation : ≈ \(Self.format(plan.estimatedBytes))"
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    // MARK: - Vidéo à glisser

    @ViewBuilder
    private var dragTile: some View {
        let tile = ZStack {
            if let thumbnail {
                Image(decorative: thumbnail, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Theme.backgroundPrimary
            }

            switch export.status {
            case .exporting(let progress):
                Color.black.opacity(0.55)
                VStack(spacing: 4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(width: 64)
                    Text("Export…")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                }
            case .ready:
                VStack {
                    Spacer()
                    Label("Glisser", systemImage: "hand.draw")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent))
                        .padding(5)
                }
            case .failed:
                Color.black.opacity(0.55)
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.error)
            case .waiting:
                EmptyView()
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(export.readyURL != nil ? Theme.accent : Theme.border, lineWidth: 1)
        )

        if let url = export.readyURL {
            tile
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .help("Glisse la vidéo vers Slack, Jira…")
        } else {
            tile
        }
    }
}
