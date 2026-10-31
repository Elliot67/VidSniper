import CoreImage
import SwiftUI

/// Cadre : contour coloré autour d'un élément. Projecteur : l'image est assombrie sauf la zone.
enum AnnotationStyle: String, Codable, Sendable {
    case frame, spotlight
}

enum AnnotationShape: String, Codable, Sendable {
    case rectangle, ellipse
}

/// Palette des annotations et des clics (couleurs d'Obsidian).
enum AnnotationColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case violet, red, yellow, green

    var id: String { rawValue }

    var hex: UInt32 {
        switch self {
        case .violet: 0x8A5CF5
        case .red: 0xFB464C
        case .yellow: 0xE0AC00
        case .green: 0x44CF6E
        }
    }

    var label: String {
        switch self {
        case .violet: "Violet"
        case .red: "Rouge"
        case .yellow: "Jaune"
        case .green: "Vert"
        }
    }

    var components: (red: CGFloat, green: CGFloat, blue: CGFloat) {
        (CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255)
    }

    var color: Color {
        Color(.sRGB, red: components.red, green: components.green, blue: components.blue)
    }

    func cgColor(alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: components.red, green: components.green, blue: components.blue, alpha: alpha)
    }
}

struct Annotation: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var style: AnnotationStyle
    var shape: AnnotationShape
    var color: AnnotationColor
    /// Zone normalisée dans l'image (0…1, origine en haut à gauche).
    var rect: CGRect
    /// Plage où l'annotation est visible à 100 %, en temps de la vidéo source (elle suit le contenu quand
    /// on coupe). Les fondus se font en dehors : 0,2 s avant `start` et 0,2 s après `end`.
    var start: Double
    var end: Double

    static let defaultDuration = 3.0
    static let minimumDuration = 0.3
    static let fadeDuration = 0.2
    /// Opacité de l'assombrissement d'un projecteur.
    static let spotlightDim = 0.6

    /// Opacité à un instant de la source : 100 % entre `start` et `end` (le bloc de la timeline),
    /// fondu d'entrée juste avant et fondu de sortie juste après. Une annotation posée à la tête de lecture
    /// y est donc entièrement visible tout de suite.
    func opacity(atSource time: Double) -> Double {
        let fade = Self.fadeDuration
        if time < start - fade || time > end + fade { return 0 }
        if time < start { return (time - (start - fade)) / fade }
        if time > end { return (end + fade - time) / fade }
        return 1
    }

    /// Épaisseur du contour d'un cadre, en pixels de la vidéo.
    static func lineWidth(videoWidth: CGFloat) -> CGFloat {
        max(3, videoWidth * 0.004)
    }

    /// Contour de la forme dans un rectangle (coins arrondis pour le rectangle).
    static func path(_ shape: AnnotationShape, in rect: CGRect) -> CGPath {
        switch shape {
        case .rectangle:
            let radius = min(rect.width, rect.height) * 0.12
            return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: rect, transform: nil)
        }
    }
}

/// Correspondance entre le temps du montage et celui de la source (segments gardés, dans l'ordre).
struct TimeMapping: Sendable {
    struct Piece: Sendable {
        let compositionStart: Double
        let sourceStart: Double
        let duration: Double
    }

    let pieces: [Piece]

    func sourceTime(at time: Double) -> Double? {
        for piece in pieces where time >= piece.compositionStart && time < piece.compositionStart + piece.duration {
            return piece.sourceStart + time - piece.compositionStart
        }
        guard let last = pieces.last, time >= last.compositionStart else { return nil }
        return last.sourceStart + min(time - last.compositionStart, last.duration)
    }

    /// Plages du montage où une plage de la source est visible (une par segment qui la contient).
    func compositionRanges(sourceStart: Double, sourceEnd: Double) -> [ClosedRange<Double>] {
        pieces.compactMap { piece in
            let start = max(sourceStart, piece.sourceStart)
            let end = min(sourceEnd, piece.sourceStart + piece.duration)
            guard end > start else { return nil }
            let offset = piece.compositionStart - piece.sourceStart
            return (start + offset)...(end + offset)
        }
    }
}

/// Rendu Core Image des annotations à l'export (l'éditeur les dessine en SwiftUI, avec les mêmes réglages).
struct AnnotationOverlay: @unchecked Sendable {
    let annotations: [Annotation]
    let mapping: TimeMapping
    /// Contours des cadres, dessinés une fois à la taille de la vidéo et déjà placés.
    private let frameImages: [UUID: CIImage]

    init(annotations: [Annotation], mapping: TimeMapping, videoSize: CGSize) {
        self.annotations = annotations
        self.mapping = mapping
        var images: [UUID: CIImage] = [:]
        for annotation in annotations where annotation.style == .frame {
            images[annotation.id] = Self.renderFrame(annotation, videoSize: videoSize)
        }
        frameImages = images
    }

    func apply(to image: CIImage, at compositionTime: Double) -> CIImage {
        guard let time = mapping.sourceTime(at: compositionTime) else { return image }
        let extent = image.extent
        var result = image

        // Projecteurs : un seul assombrissement, percé de toutes les zones visibles.
        let spotlights = annotations.filter { $0.style == .spotlight && $0.opacity(atSource: time) > 0 }
        if let opacity = spotlights.map({ $0.opacity(atSource: time) }).max(),
           let mask = Self.spotlightMask(spotlights, extent: extent) {
            let dim = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: Annotation.spotlightDim * opacity))
                .cropped(to: extent)
                .applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputBackgroundImageKey: CIImage.empty(),
                    kCIInputMaskImageKey: mask,
                ])
            result = dim.composited(over: result)
        }

        for annotation in annotations where annotation.style == .frame {
            let opacity = annotation.opacity(atSource: time)
            guard opacity > 0, let frame = frameImages[annotation.id] else { continue }
            let mark = frame
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
                .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
            result = mark.composited(over: result)
        }
        return result
    }

    /// Zone en pixels, origine en bas à gauche (Core Image).
    private static func pixelRect(_ rect: CGRect, in size: CGSize) -> CGRect {
        CGRect(x: rect.minX * size.width, y: (1 - rect.maxY) * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }

    private static func renderFrame(_ annotation: Annotation, videoSize: CGSize) -> CIImage? {
        let lineWidth = Annotation.lineWidth(videoWidth: videoSize.width)
        let shape = pixelRect(annotation.rect, in: videoSize)
        let padding = lineWidth * 4
        let canvas = shape.insetBy(dx: -padding, dy: -padding).integral
        guard canvas.width > 0, canvas.height > 0, let context = CGContext(
            data: nil, width: Int(canvas.width), height: Int(canvas.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let local = shape.offsetBy(dx: -canvas.minX, dy: -canvas.minY)
        // Ombre légère : le contour reste lisible sur un fond clair comme sombre.
        context.setShadow(offset: .zero, blur: lineWidth * 1.5, color: CGColor(gray: 0, alpha: 0.5))
        context.addPath(Annotation.path(annotation.shape, in: local))
        context.setStrokeColor(annotation.color.cgColor())
        context.setLineWidth(lineWidth)
        context.strokePath()

        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: canvas.minX, y: canvas.minY))
    }

    /// Masque des projecteurs : blanc là où l'image est assombrie, noir dans les zones éclairées.
    /// Dessiné en basse résolution (640 px de large) puis agrandi : les bords restent doux.
    private static func spotlightMask(_ spotlights: [Annotation], extent: CGRect) -> CIImage? {
        guard extent.width > 0, extent.height > 0 else { return nil }
        let width = 640
        let height = max(1, Int(CGFloat(width) * extent.height / extent.width))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        let size = CGSize(width: width, height: height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: size))
        context.setFillColor(gray: 0, alpha: 1)
        for spotlight in spotlights {
            context.addPath(Annotation.path(spotlight.shape, in: pixelRect(spotlight.rect, in: size)))
            context.fillPath()
        }

        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image)
            .transformed(by: CGAffineTransform(scaleX: extent.width / CGFloat(width), y: extent.height / CGFloat(height)))
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
    }
}
