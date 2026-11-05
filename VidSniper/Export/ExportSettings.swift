import AVFoundation
import CoreGraphics
import Foundation

/// Définition de l'export : tous les pixels capturés (Retina), ou la taille vue à l'écran. Jamais en dessous :
/// le texte deviendrait illisible, mieux vaut alors compresser davantage.
enum ExportResolution: String, CaseIterable, Identifiable, Sendable {
    case full, screen

    var id: String { rawValue }

    /// Part de la définition capturée gardée, selon les pixels par point de l'enregistrement.
    func factor(pixelsPerPoint: Double) -> Double {
        switch self {
        case .full: 1
        case .screen: 1 / max(pixelsPerPoint, 1)
        }
    }
}

/// Compression, de la plus fidèle à la plus légère. Chaque niveau divise le débit par ~1,7.
enum ExportQuality: String, CaseIterable, Identifiable, Sendable {
    case maximum, high, balanced, light, veryLight

    var id: String { rawValue }

    var label: String {
        switch self {
        case .maximum: String(localized: "Maximum")
        case .high: String(localized: "High")
        case .balanced: String(localized: "Balanced")
        case .light: String(localized: "Light")
        case .veryLight: String(localized: "Very Light")
        }
    }

    /// Bits par pixel et par image : le débit vidéo cible en découle.
    var bitsPerPixel: Double {
        switch self {
        case .maximum: 0.12
        case .high: 0.07
        case .balanced: 0.04
        case .light: 0.024
        case .veryLight: 0.014
        }
    }
}

/// Gain linéaire d'une piste audio du montage (normalisation + balance). Peut dépasser 1 : il est appliqué
/// par `AudioGain`, pas par `setVolume`.
struct AudioTrackVolume: Equatable, Sendable {
    let trackID: CMPersistentTrackID
    let volume: Float
}

/// Espace colorimétrique de toute la chaîne : capture en sRGB, enregistrement et MP4 étiquetés pareil
/// (primaires et matrice BT.709, courbe sRGB). Sans étiquette, l'enregistrement était affiché tel quel,
/// étiré sur la gamme de l'écran (plus vif), alors que le MP4 était converti : les couleurs différaient.
enum VideoColor {
    static let properties: [String: String] = [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
    ]

    /// Composition rendue dans ce même espace, pour que le MP4 garde les couleurs de l'enregistrement.
    static func apply(to composition: AVMutableVideoComposition) {
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_IEC_sRGB
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
    }
}

/// Paramètres concrets d'un export, et le poids estimé qui en découle.
struct ExportPlan: Equatable, Sendable {
    static let frameRate = 30.0
    /// Au plus une image complète toutes les 10 s (l'encodeur en ajoute de lui-même quand l'image change
    /// d'un coup). Sur un écran presque immobile, ce sont elles qui pèsent : plus espacées, elles laissent
    /// des bits aux passages qui bougent. Seule contrepartie : un déplacement repart de la dernière.
    static let keyFrameInterval = 10.0
    /// Plancher de sécurité. Plus haut (500 kb/s), il rendait les niveaux bas identiques sur les petites zones.
    private static let minimumVideoBitrate = 200_000
    static let audioBitrate = 128_000
    /// Limites du H.264 matériel d'Apple : un enregistrement 5K doit être réduit.
    private static let maxLongSide = 4096.0
    private static let maxShortSide = 2304.0

    let width: Int
    let height: Int
    let videoBitrate: Int
    let hasAudio: Bool
    let duration: Double

    init(
        sourceSize: CGSize,
        pixelsPerPoint: Double,
        duration: Double,
        hasAudio: Bool,
        resolution: ExportResolution,
        quality: ExportQuality
    ) {
        let longSide = max(sourceSize.width, sourceSize.height)
        let shortSide = min(sourceSize.width, sourceSize.height)
        let factor = min(
            resolution.factor(pixelsPerPoint: pixelsPerPoint),
            Self.maxLongSide / max(longSide, 1),
            Self.maxShortSide / max(shortSide, 1)
        )
        width = max(2, Int((sourceSize.width * factor).rounded()) & ~1)
        height = max(2, Int((sourceSize.height * factor).rounded()) & ~1)
        videoBitrate = max(Self.minimumVideoBitrate, Int(Double(width * height) * Self.frameRate * quality.bitsPerPixel))
        self.hasAudio = hasAudio
        self.duration = duration
    }

    var estimatedBytes: Int64 {
        let bitsPerSecond = Double(videoBitrate + (hasAudio ? Self.audioBitrate : 0))
        // ~1 % pour le conteneur MP4.
        return Int64(bitsPerSecond * duration / 8 * 1.01)
    }
}
