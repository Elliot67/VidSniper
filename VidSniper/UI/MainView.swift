import SwiftUI

struct MainView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(Permissions.self) private var permissions

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing * 1.5) {
            VStack(alignment: .leading, spacing: 4) {
                Text("VidSniper")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.textNormal)
                Text("Enregistre une zone de l'écran, coupe, partage.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textMuted)
            }

            HStack(spacing: Theme.spacing) {
                Button("Nouvel enregistrement") { coordinator.startSelection() }
                    .buttonStyle(AccentButtonStyle())
                    .disabled(!permissions.screenRecording || coordinator.state != .idle)
                Text(coordinator.shortcut.label)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textMuted)
            }

            if let error = coordinator.lastError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.error)
            }

            if let recording = coordinator.lastRecording {
                lastRecordingPanel(recording)
            }

            permissionsPanel

            launchAtLoginPanel

            Spacer(minLength: 0)
        }
        .padding(Theme.spacing * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.backgroundPrimary)
        // Rafraîchit au retour depuis les Réglages système.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            permissions.refresh()
        }
    }

    /// Permet de rouvrir l'éditeur si on l'a fermé par erreur.
    private func lastRecordingPanel(_ recording: RecordingResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.url.lastPathComponent)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textNormal)
                Text(audioSummary(recording))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            Button("Ouvrir l'éditeur") {
                coordinator.openEditor(recording)
            }
            .buttonStyle(SecondaryButtonStyle())
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

    private func audioSummary(_ recording: RecordingResult) -> String {
        var tracks = ["Vidéo"]
        if recording.hasSystemAudio { tracks.append("son système") }
        if recording.hasMicrophone { tracks.append("micro") }
        return tracks.joined(separator: " + ")
    }

    /// Réglages : raccourci global et lancement à l'ouverture de session.
    private var launchAtLoginPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RÉGLAGES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.spacing)
                .padding(.vertical, 8)

            Divider().overlay(Theme.border)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Raccourci global")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textNormal)
                    Text(coordinator.shortcutMessage ?? "Lance la sélection de zone, puis arrête l'enregistrement.")
                        .font(.system(size: 11))
                        .foregroundStyle(coordinator.shortcutMessage == nil ? Theme.textMuted : Theme.error)
                }
                Spacer()
                shortcutRecorder
            }
            .padding(.horizontal, Theme.spacing)
            .padding(.vertical, 9)

            Divider().overlay(Theme.border)

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lancer à l'ouverture de session")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textNormal)
                    Text("Garde \(coordinator.shortcut.label) disponible sans ouvrir l'app.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { coordinator.launchAtLogin.isEnabled },
                    set: { coordinator.launchAtLogin.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .tint(Theme.accent)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, Theme.spacing)
            .padding(.vertical, 9)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
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
                Text(isRecording ? "Tape le raccourci… (Esc)" : coordinator.shortcut.label)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isRecording ? Theme.accent : Theme.textNormal)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cliquer, puis taper le nouveau raccourci")

            if canReset {
                Button {
                    coordinator.setShortcut(.standard)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                .buttonStyle(.plain)
                .help("Revenir à \(Shortcut.standard.label)")
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

    private var permissionsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("PERMISSIONS")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textMuted)
                .padding(.horizontal, Theme.spacing)
                .padding(.vertical, 8)

            Divider().overlay(Theme.border)

            PermissionRow(
                title: "Enregistrement de l'écran",
                granted: permissions.screenRecording,
                action: { permissions.requestScreenRecording() }
            )

            Divider().overlay(Theme.border)

            PermissionRow(
                title: "Micro",
                detail: "Optionnel",
                granted: permissions.microphone == .authorized,
                required: false,
                action: { Task { await permissions.requestMicrophone() } }
            )
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .fill(Theme.backgroundSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct PermissionRow: View {
    let title: String
    var detail: String? = nil
    let granted: Bool
    var required = true
    let action: () -> Void

    private var statusColor: Color {
        if granted { return Theme.success }
        return required ? Theme.error : Theme.textMuted
    }

    var body: some View {
        HStack {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textNormal)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
            }
            Spacer()
            if granted {
                Text("Accordé")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textMuted)
            } else {
                Button("Autoriser", action: action)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, Theme.spacing)
        .padding(.vertical, 9)
    }
}
