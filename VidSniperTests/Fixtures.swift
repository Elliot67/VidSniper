import Foundation
import Testing
@testable import VidSniper

/// Vidéos de test. Les générées (`./scripts/make-fixtures.sh`) sont dans build/fixtures, non versionnées ;
/// le vrai enregistrement de référence est versionné dans VidSniperTests/Fixtures.
enum Fixtures {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Comme un enregistrement VidSniper : HEVC 1280 × 720, 60 i/s, 3 s, mire étiquetée BT.709 / sRGB,
    /// deux pistes audio (son système, micro).
    static var recording: URL {
        get throws { try generated("recording.mov") }
    }

    /// Vidéo importée minimale : H.264 640 × 360 sans étiquette de couleur, une piste audio, 2 s.
    static var imported: URL {
        get throws { try generated("imported.mp4") }
    }

    /// Vrai enregistrement fait avec l'app (absent tant qu'il n'a pas été ajouté au dépôt).
    static var reference: URL? {
        let url = root.appending(path: "VidSniperTests/Fixtures/reference.mov")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// `./scripts/test.sh` active les tests d'intégration, qui encodent réellement (encodeur vidéo de macOS).
    static let runsIntegration = ProcessInfo.processInfo.environment["VIDSNIPER_INTEGRATION"] == "1"

    private static func generated(_ name: String) throws -> URL {
        let url = root.appending(path: "build/fixtures/\(name)")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixtureError.missing(name)
        }
        return url
    }

    enum FixtureError: Error, CustomStringConvertible {
        case missing(String)

        var description: String {
            switch self {
            case .missing(let name): "build/fixtures/\(name) manquant : lancer ./scripts/make-fixtures.sh"
            }
        }
    }
}

/// Égalité à une tolérance près (durées, temps).
func isClose(_ a: Double, _ b: Double, tolerance: Double = 0.02) -> Bool {
    abs(a - b) <= tolerance
}
