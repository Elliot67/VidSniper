import AppKit
import CoreGraphics
import Foundation
import Observation

/// Zone à enregistrer : un écran et un rectangle en points, origine en haut à gauche de cet écran.
struct CaptureRegion: Codable, Sendable {
    let displayID: CGDirectDisplayID
    let rect: CGRect

    var screen: NSScreen? {
        NSScreen.screens.first { $0.displayID == displayID }
    }

    /// Le rectangle en coordonnées globales AppKit (origine en bas à gauche de l'écran principal).
    func globalRect(on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private static let defaultsKey = "lastCaptureRegion"

    static var last: CaptureRegion? {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
            return try? JSONDecoder().decode(CaptureRegion.self, from: data)
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: defaultsKey)
        }
    }
}

struct CaptureOptions: Sendable {
    let microphone: Bool
    let systemAudio: Bool
}

/// Résultat d'un enregistrement. Les pistes audio sont écrites dans l'ordre : son système, puis micro.
struct RecordingResult: Sendable {
    let url: URL
    let hasSystemAudio: Bool
    let hasMicrophone: Bool
}

/// Interrupteurs audio du sélecteur de zone, mémorisés d'une capture à l'autre.
@MainActor
@Observable
final class SelectionOptions {
    var microphone: Bool {
        didSet { UserDefaults.standard.set(microphone, forKey: "captureMicrophone") }
    }
    var systemAudio: Bool {
        didSet { UserDefaults.standard.set(systemAudio, forKey: "captureSystemAudio") }
    }

    init() {
        let defaults = UserDefaults.standard
        microphone = defaults.object(forKey: "captureMicrophone") as? Bool ?? true
        systemAudio = defaults.object(forKey: "captureSystemAudio") as? Bool ?? true
    }
}

/// Chrono de la mini barre, en tenant compte des pauses.
@MainActor
@Observable
final class RecordingSession {
    private(set) var startedAt: Date?
    private(set) var pausedAt: Date?
    private var pausedTotal: TimeInterval = 0

    var isPaused: Bool { pausedAt != nil }

    func start() {
        startedAt = .now
        pausedAt = nil
        pausedTotal = 0
    }

    func pause() {
        pausedAt = .now
    }

    func resume() {
        if let pausedAt { pausedTotal += Date.now.timeIntervalSince(pausedAt) }
        pausedAt = nil
    }

    func elapsed(at date: Date) -> TimeInterval {
        guard let startedAt else { return 0 }
        return max(0, (pausedAt ?? date).timeIntervalSince(startedAt) - pausedTotal)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
