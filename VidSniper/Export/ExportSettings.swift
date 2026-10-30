import AVFoundation
import CoreGraphics
import Foundation

enum ExportSize: Double, CaseIterable, Identifiable, Sendable {
    case full = 1
    case threeQuarters = 0.75
    case half = 0.5

    var id: Double { rawValue }

    var label: String {
        "\(Int(rawValue * 100)) %"
    }
}

enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
    case high, medium, light

    var id: String { rawValue }

    var label: String {
        switch self {
        case .high: "Haute"
        case .medium: "Moyenne"
        case .light: "Légère"
        }
    }

    /// Bits par pixel et par image : le débit vidéo cible en découle.
    var bitsPerPixel: Double {
        switch self {
        case .high: 0.10
        case .medium: 0.06
        case .light: 0.035
        }
    }
}

/// Gain linéaire d'une piste audio du montage (normalisation + balance). Peut dépasser 1 : il est appliqué
/// par `AudioGain`, pas par `setVolume`.
struct AudioTrackVolume: Equatable, Sendable {
    let trackID: CMPersistentTrackID
    let volume: Float
}

/// Paramètres concrets d'un export, et le poids estimé qui en découle.
struct ExportPlan: Equatable, Sendable {
    static let frameRate = 30.0
    static let audioBitrate = 128_000
    /// Limites du H.264 matériel d'Apple : un enregistrement 5K doit être réduit.
    private static let maxLongSide = 4096.0
    private static let maxShortSide = 2304.0

    let width: Int
    let height: Int
    let videoBitrate: Int
    let hasAudio: Bool
    let duration: Double

    init(sourceSize: CGSize, duration: Double, hasAudio: Bool, size: ExportSize, quality: ExportQuality) {
        let longSide = max(sourceSize.width, sourceSize.height)
        let shortSide = min(sourceSize.width, sourceSize.height)
        let factor = min(size.rawValue, Self.maxLongSide / max(longSide, 1), Self.maxShortSide / max(shortSide, 1))
        width = max(2, Int((sourceSize.width * factor).rounded()) & ~1)
        height = max(2, Int((sourceSize.height * factor).rounded()) & ~1)
        videoBitrate = max(500_000, Int(Double(width * height) * Self.frameRate * quality.bitsPerPixel))
        self.hasAudio = hasAudio
        self.duration = duration
    }

    var estimatedBytes: Int64 {
        let bitsPerSecond = Double(videoBitrate + (hasAudio ? Self.audioBitrate : 0))
        // ~1 % pour le conteneur MP4.
        return Int64(bitsPerSecond * duration / 8 * 1.01)
    }
}
