import SwiftUI

/// Panneau de l'onglet Export : taille et qualité (avec le poids de chaque option), poids du MP4,
/// et la vidéo prête à glisser ou copier.
struct ExportPanel: View {
    let export: ExportModel
    let thumbnail: CGImage?

    var body: some View {
        HStack(alignment: .center, spacing: Theme.spacing * 1.5) {
            VStack(alignment: .leading, spacing: 6) {
                // Sans enregistrement Retina, une seule définition possible : pas de choix à montrer.
                if export.hasScreenResolution {
                    optionRow("Resolution") {
                        ForEach(ExportResolution.allCases) { resolution in
                            OptionTile(
                                title: resolutionTitle(resolution),
                                detail: export.plan(resolution: resolution, quality: export.quality)
                                    .map { "\($0.width) × \($0.height)" },
                                // Le poids n'est montré que pour la compression.
                                weight: nil,
                                isSelected: export.resolution == resolution
                            ) {
                                export.resolution = resolution
                            }
                        }
                    }
                }
                optionRow("Compression") {
                    ForEach(ExportQuality.allCases) { quality in
                        OptionTile(
                            title: quality.label,
                            weight: export.weight(resolution: export.resolution, quality: quality),
                            isSelected: export.quality == quality
                        ) {
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
                    // La confirmation s'affiche au-dessus de la vidéo, dans les deux onglets (CopiedToast).
                    HStack(spacing: 6) {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 16, height: 14)
                        Text("Copy")
                    }
                    .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(AccentButtonStyle())
                .disabled(export.readyURL == nil)
                .help("Copy the video to paste it into Slack, Jira… (⌘C)")

                Button {
                    export.saveAs()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.doc")
                            .frame(width: 16, height: 14)
                        Text("Save…")
                    }
                    .frame(minWidth: 96, maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(SecondaryButtonStyle(large: true))
                .disabled(export.readyURL == nil)
                .help("Save a copy of the video (⌘S)")
            }
            // Les deux boutons prennent la largeur du plus long libellé (qui change avec la langue).
            .fixedSize(horizontal: true, vertical: false)
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

    private func resolutionTitle(_ resolution: ExportResolution) -> String {
        switch resolution {
        case .full: String(localized: "Retina")
        case .screen: String(localized: "Screen")
        }
    }

    private func optionRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 72, alignment: .leading)
            content()
        }
    }

    // MARK: - Résumé

    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let plan = export.plan {
                Text(verbatim: "\(plan.width) × \(plan.height) · MP4")
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
            return String(localized: "Size: \(Self.format(bytes))")
        default:
            guard let plan = export.plan else { return "" }
            return String(localized: "Estimate: ≈ \(Self.format(plan.estimatedBytes))")
        }
    }

    static func format(_ bytes: Int64) -> String {
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
                    Text("Exporting…")
                        .font(.system(size: 10))
                        .foregroundStyle(.white)
                }
            case .ready:
                VStack {
                    Spacer()
                    Label("Drag", systemImage: "hand.draw")
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
                .help("Drag the video into Slack, Jira…")
        } else {
            tile
        }
    }
}

/// Option de taille ou de qualité, avec le poids qu'aurait la vidéo : réel si ce réglage a déjà été
/// exporté, sinon estimé (≈).
private struct OptionTile: View {
    let title: String
    /// Ligne ajoutée avant le poids, ou à sa place (dimensions d'une définition).
    var detail: String?
    let weight: (bytes: Int64, isEstimate: Bool)?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Theme.textNormal)
                Text(verbatim: weightText)
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Theme.textMuted)
            }
            .frame(minWidth: 70, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .fill(isSelected ? Theme.accent : Theme.backgroundPrimary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .stroke(isSelected ? Theme.accent : Theme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var weightText: String {
        guard let weight else { return detail ?? "–" }
        let size = ExportPanel.format(weight.bytes)
        let text = weight.isEstimate ? "≈ \(size)" : size
        return detail.map { "\($0) · \(text)" } ?? text
    }
}
