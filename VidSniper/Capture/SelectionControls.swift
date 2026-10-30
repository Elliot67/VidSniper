import Observation
import SwiftUI

/// État de la sélection affiché par le panneau (mis à jour par SelectionView).
@MainActor
@Observable
final class SelectionControlsState {
    var hasSelection = false
    var isFullScreen = false
}

/// Panneau du sélecteur : plein écran, sources audio, Annuler, Enregistrer.
struct SelectionControls: View {
    @Bindable var options: SelectionOptions
    let state: SelectionControlsState
    let microphoneAvailable: Bool
    let onToggleFullScreen: () -> Void
    let onRecord: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ToggleChip(
                isOn: Binding(get: { state.isFullScreen }, set: { _ in onToggleFullScreen() }),
                title: state.isFullScreen ? "Quitter le plein écran" : "Plein écran",
                onIcon: "arrow.down.right.and.arrow.up.left",
                offIcon: "arrow.up.left.and.arrow.down.right"
            )
            .help(state.isFullScreen ? "Revenir à la zone précédente" : "Enregistrer tout l'écran")

            separator

            ToggleChip(
                isOn: Binding(
                    get: { options.microphone && microphoneAvailable },
                    set: { options.microphone = $0 }
                ),
                title: "Micro",
                onIcon: "mic.fill",
                offIcon: "mic.slash.fill"
            )
            .disabled(!microphoneAvailable)
            .help(microphoneAvailable ? "Enregistrer le micro" : "Micro non autorisé (voir la fenêtre principale)")

            ToggleChip(
                isOn: $options.systemAudio,
                title: "Son système",
                onIcon: "speaker.wave.2.fill",
                offIcon: "speaker.slash.fill"
            )

            separator

            Button("Annuler", action: onCancel)
                .buttonStyle(SecondaryButtonStyle())

            Button(action: onRecord) {
                Label("Enregistrer", systemImage: "record.circle")
            }
            .buttonStyle(AccentButtonStyle())
            .disabled(!state.hasSelection)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: Theme.cornerRadius + 2)
                .fill(Theme.backgroundPrimary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius + 2)
                .stroke(Theme.border, lineWidth: 1)
        )
        .fixedSize()
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.border)
            .frame(width: 1, height: 20)
    }
}
