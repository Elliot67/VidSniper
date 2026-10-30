import AppKit
import Observation
import ServiceManagement

/// Lancement à l'ouverture de session : nécessaire pour que le raccourci global marche sans ouvrir l'app.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("VidSniper: login item update failed: \(error)")
        }
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    /// Vrai si l'app vient d'être lancée automatiquement à l'ouverture de session.
    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
