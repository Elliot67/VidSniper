import SwiftUI

/// Page d'accueil : logo, deux actions (enregistrer, importer), dernière vidéo, réglages.
struct MainView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(Permissions.self) private var permissions

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing * 1.75) {
            header
            actions

            if let error = coordinator.lastError {
                errorBanner(error)
            }

            if let recording = coordinator.lastRecording {
                lastRecordingCard(recording)
            }

            settingsCard

            Spacer(minLength: 0)
        }
        .padding(Theme.spacing * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.backgroundPrimary)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // Glisser une vidéo sur la fenêtre l'ouvre dans l'éditeur.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            coordinator.openVideo(at: url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        // Rafraîchit au retour depuis les Réglages système.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    // MARK: - En-tête

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: "VidSniper")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.textNormal)
                Text("Record an area of your screen, trim it, share it.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: Theme.spacing) {
            ActionTile(
                icon: "record.circle",
                title: String(localized: "New Recording"),
                detail: coordinator.shortcut.label,
                isPrimary: true,
                action: coordinator.startSelection
            )
            .disabled(!permissions.screenRecording || coordinator.state != .idle)
            .help(permissions.screenRecording ? "Choose an area of the screen to record" : "Allow screen recording first")

            ActionTile(
                icon: "square.and.arrow.down",
                title: String(localized: "Import Video"),
                detail: String(localized: "⌘O or drop a file"),
                isPrimary: false,
                action: coordinator.importVideo
            )
            .help("Open an existing video in the editor")
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.error)
        .padding(.horizontal, Theme.spacing)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.error.opacity(0.1))
        )
    }

    // MARK: - Dernière vidéo

    /// Permet de rouvrir l'éditeur si on l'a fermé par erreur.
    private func lastRecordingCard(_ recording: RecordingResult) -> some View {
        Card(title: String(localized: "Latest Video")) {
            SettingsRow(icon: "film", title: recording.url.deletingPathExtension().lastPathComponent, detail: audioSummary(recording)) {
                Button("Open") {
                    coordinator.openEditor(recording)
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private func audioSummary(_ recording: RecordingResult) -> String {
        var tracks = [recording.isImported ? String(localized: "Imported video") : String(localized: "Recording")]
        if recording.hasSystemAudio { tracks.append(recording.audioTitle(microphone: false).lowercased()) }
        if recording.hasMicrophone { tracks.append(recording.audioTitle(microphone: true).lowercased()) }
        return tracks.joined(separator: " · ")
    }

    // MARK: - Réglages

    private var settingsCard: some View {
        Card(title: String(localized: "Settings")) {
            SettingsRow(
                icon: "keyboard",
                title: String(localized: "Global shortcut"),
                detail: coordinator.shortcutMessage ?? String(localized: "Starts the area selection, then stops the recording."),
                detailIsError: coordinator.shortcutMessage != nil
            ) {
                shortcutRecorder
            }

            Divider().overlay(Theme.border)

            SettingsRow(
                icon: "power",
                title: String(localized: "Launch at login"),
                detail: String(localized: "Keeps \(coordinator.shortcut.label) available without opening the app.")
            ) {
                Toggle("", isOn: Binding(
                    get: { coordinator.launchAtLogin.isEnabled },
                    set: { coordinator.launchAtLogin.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .labelsHidden()
                .controlSize(.small)
            }

            Divider().overlay(Theme.border)

            SettingsRow(
                icon: "rectangle.dashed.badge.record",
                title: String(localized: "Screen recording"),
                detail: String(localized: "Required to capture an area.")
            ) {
                PermissionStatus(granted: permissions.screenRecording, required: true) {
                    permissions.requestScreenRecording()
                }
            }

            Divider().overlay(Theme.border)

            SettingsRow(
                icon: "mic",
                title: String(localized: "Microphone"),
                detail: String(localized: "Optional, to record your voice.")
            ) {
                PermissionStatus(granted: permissions.microphone == .authorized, required: false) {
                    Task { await permissions.requestMicrophone() }
                }
            }
        }
    }

    /// Une seule pastille : clic sur le raccourci pour en taper un nouveau (Esc pour annuler),
    /// croix intégrée pour revenir au raccourci par défaut.
    private var shortcutRecorder: some View {
        let isRecording = coordinator.isRecordingShortcut
        let canReset = coordinator.shortcut != .standard && !isRecording

        return HStack(spacing: 6) {
            Button {
                if isRecording {
                    coordinator.endShortcutRecording()
                } else {
                    coordinator.beginShortcutRecording()
                }
            } label: {
                (isRecording ? Text("Type the shortcut… (Esc)") : Text(verbatim: coordinator.shortcut.label))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isRecording ? Theme.accent : Theme.textNormal)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Click, then type the new shortcut")

            if canReset {
                Button {
                    coordinator.setShortcut(.standard)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Reset to \(Shortcut.standard.label)")
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, canReset ? 6 : 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.backgroundPrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(isRecording ? Theme.accent : Theme.border, lineWidth: 1)
        )
        .onDisappear { coordinator.endShortcutRecording() }
    }
}

/// Grande tuile d'action de la page d'accueil (icône, titre, détail).
private struct ActionTile: View {
    let icon: String
    let title: String
    let detail: String
    let isPrimary: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(isPrimary ? Color.white : Theme.accent)
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isPrimary ? Color.white : Theme.textNormal)
                    Text(detail)
                        .font(.system(size: 11, design: isPrimary ? .monospaced : .default))
                        .foregroundStyle(isPrimary ? Color.white.opacity(0.75) : Theme.textMuted)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isPrimary ? Color.clear : Theme.border, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovered = $0 }
    }

    private var fill: Color {
        if isPrimary { return isHovered && isEnabled ? Theme.accentHover : Theme.accent }
        return isHovered && isEnabled ? Theme.border.opacity(0.6) : Theme.backgroundSecondary
    }
}

/// Carte avec un titre de section et des lignes séparées par de fins traits.
private struct Card<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .padding(.leading, 2)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.backgroundSecondary)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Theme.border, lineWidth: 1)
            )
        }
    }
}

/// Ligne de réglage : icône alignée, titre et détail, contrôle à droite.
private struct SettingsRow<Trailing: View>: View {
    let icon: String
    let title: String
    let detail: String
    var detailIsError = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textMuted)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textNormal)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(detailIsError ? Theme.error : Theme.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: Theme.spacing)
            trailing
        }
        .padding(.horizontal, Theme.spacing)
        .padding(.vertical, 10)
    }
}

/// État d'une permission : "Accordé" (point vert), ou bouton "Autoriser" (point rouge si obligatoire).
private struct PermissionStatus: View {
    let granted: Bool
    let required: Bool
    let action: () -> Void

    var body: some View {
        if granted {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.success)
                    .frame(width: 7, height: 7)
                Text("Granted")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            }
        } else {
            HStack(spacing: 8) {
                Circle()
                    .fill(required ? Theme.error : Theme.textMuted)
                    .frame(width: 7, height: 7)
                Button("Allow", action: action)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}
