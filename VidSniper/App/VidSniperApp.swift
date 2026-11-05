import SwiftUI

@main
struct VidSniperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // La fenêtre principale est gérée par AppCoordinator, pour pouvoir la masquer/réafficher librement.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .newItem) {
                    Button("Import Video…") { appDelegate.importVideo() }
                        .keyboardShortcut("o")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AppCoordinator?
    /// Vidéos reçues (Dock, "Ouvrir avec") avant que l'app ait fini de démarrer.
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hôte des tests : ni fenêtre, ni raccourci global, ni demande d'autorisation.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        RecordingStore.purgeOldRecordings()
        let coordinator = AppCoordinator()
        // Lancée à l'ouverture de session : on reste discret, seul le raccourci est actif.
        if !LaunchAtLogin.launchedAsLoginItem, pendingURLs.isEmpty {
            coordinator.showMainWindow()
        }
        Task { await coordinator.permissions.prepareScreenCapture() }
        self.coordinator = coordinator

        pendingURLs.forEach { coordinator.openVideo(at: $0) }
        pendingURLs.removeAll()
    }

    // L'app reste lancée sans fenêtre, pour que le raccourci global continue de marcher.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { coordinator?.showMainWindow() }
        return true
    }

    /// Vidéo glissée sur l'icône du Dock, ou ouverte avec VidSniper depuis le Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let coordinator else {
            pendingURLs.append(contentsOf: urls)
            return
        }
        urls.forEach { coordinator.openVideo(at: $0) }
    }

    func importVideo() {
        coordinator?.importVideo()
    }
}
