@preconcurrency import AVFoundation
import AppKit
import CoreGraphics
import Observation
@preconcurrency import ScreenCaptureKit

/// État des permissions système nécessaires : enregistrement d'écran et micro.
@MainActor
@Observable
final class Permissions {
    private(set) var screenRecording = false
    private(set) var microphone: AVAuthorizationStatus = .notDetermined

    init() {
        refresh()
    }

    func refresh() {
        screenRecording = CGPreflightScreenCaptureAccess()
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func requestScreenRecording() {
        // Affiche la demande système la première fois. Ensuite, seul le réglage système permet de l'accorder.
        if !CGRequestScreenCaptureAccess() {
            openSettings(anchor: "Privacy_ScreenCapture")
        }
        refresh()
        Task { await prepareScreenCapture() }
    }

    /// macOS (15+) demande périodiquement de confirmer l'accès direct à l'écran ("contourner le sélecteur
    /// de fenêtre privée"). On interroge ScreenCaptureKit dès le lancement pour que cette demande
    /// apparaisse ici, et pas au moment de lancer un enregistrement.
    func prepareScreenCapture() async {
        guard screenRecording else { return }
        _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    func requestMicrophone() async {
        switch microphone {
        case .notDetermined:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            openSettings(anchor: "Privacy_Microphone")
        default:
            break
        }
        refresh()
    }

    private func openSettings(anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
