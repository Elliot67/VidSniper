import SwiftUI

@main
struct VidSniperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // La fenêtre principale est gérée par AppCoordinator, pour pouvoir la masquer/réafficher librement.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        RecordingStore.purgeOldRecordings()
        let coordinator = AppCoordinator()
        // Lancée à l'ouverture de session : on reste discret, seul le raccourci est actif.
        if !LaunchAtLogin.launchedAsLoginItem {
            coordinator.showMainWindow()
        }
        Task { await coordinator.permissions.prepareScreenCapture() }
        self.coordinator = coordinator
    }

    // L'app reste lancée sans fenêtre, pour que le raccourci global continue de marcher.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { coordinator?.showMainWindow() }
        return true
    }
}
