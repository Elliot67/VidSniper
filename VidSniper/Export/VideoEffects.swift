import AVFoundation
import CoreImage

/// Un clic pendant l'enregistrement : instant (secondes) et position normalisée dans la zone (0…1, origine en haut à gauche).
struct ClickMark: Codable, Equatable, Sendable {
    let time: Double
    let x: Double
    let y: Double
}

/// Animation dessinée à chaque clic : deux bulles qui grandissent et s'effacent l'une sur l'autre.
/// - un disque violet translucide cerclé (0,5 s, jusqu'au rayon) ;
/// - une onde : un simple contour fin, qui part 0,2 s plus tard, dure plus longtemps (0,6 s)
///   et va plus loin (2 × le rayon). On voit d'abord le petit disque, puis la grande onde.
/// Les instants sont ceux du montage (déjà convertis depuis la source).
struct ClickOverlay: @unchecked Sendable {
    /// Une bulle : image de base et animation (décalage, durée, rayon de départ et d'arrivée en fraction du rayon).
    private struct Bubble {
        let image: CIImage
        let delay: Double
        let duration: Double
        let startScale: Double
        let endScale: Double
        /// Opacité selon l'avancement (0 → 1).
        let opacity: (Double) -> Double
    }

    let clicks: [ClickMark]
    /// Rayon de référence, en fraction de la largeur de la vidéo.
    let radius: Double
    private let bubbles: [Bubble]
    private let duration: Double

    private static let imageSize: CGFloat = 256

    init(clicks: [ClickMark], radius: Double, color: AnnotationColor) {
        self.clicks = clicks
        self.radius = radius
        bubbles = [
            Bubble(
                image: Self.makeBubble(color: color, fillAlpha: 0.3, lineWidth: 14),
                delay: 0, duration: 0.5, startScale: 0.45, endScale: 1,
                // Reste bien visible, puis s'efface vers la fin.
                opacity: { 1 - $0 * $0 }
            ),
            Bubble(
                image: Self.makeBubble(color: color, fillAlpha: 0, lineWidth: 5),
                delay: 0.2, duration: 0.6, startScale: 0.5, endScale: 2,
                // S'efface dès le départ : déjà très transparente quand elle atteint sa taille maximale.
                opacity: { pow(1 - $0, 1.5) }
            ),
        ]
        duration = bubbles.map { $0.delay + $0.duration }.max() ?? 0
    }

    func apply(to image: CIImage, at time: Double) -> CIImage {
        let extent = image.extent
        var result = image
        for click in clicks where time >= click.time && time < click.time + duration {
            // Core Image a son origine en bas à gauche.
            let center = CGPoint(x: extent.minX + click.x * extent.width, y: extent.minY + (1 - click.y) * extent.height)
            for bubble in bubbles {
                let start = click.time + bubble.delay
                guard time >= start, time < start + bubble.duration else { continue }
                let progress = (time - start) / bubble.duration
                let eased = 1 - pow(1 - progress, 3)
                let scale = bubble.startScale + (bubble.endScale - bubble.startScale) * eased
                let radius = self.radius * extent.width * scale
                let alpha = bubble.opacity(progress)
                let factor = 2 * radius / Self.imageSize
                let mark = bubble.image
                    .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
                    .transformed(by: CGAffineTransform(translationX: center.x - radius, y: center.y - radius))
                    .applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)])
                result = mark.composited(over: result)
            }
        }
        return result
    }

    /// Bulle colorée (remplissage translucide et contour), dessinée une fois puis mise à l'échelle à chaque image.
    private static func makeBubble(color: AnnotationColor, fillAlpha: CGFloat, lineWidth: CGFloat) -> CIImage {
        let size = Int(imageSize)
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return CIImage.empty() }

        let rect = CGRect(x: 0, y: 0, width: imageSize, height: imageSize).insetBy(dx: 10, dy: 10)
        if fillAlpha > 0 {
            context.setFillColor(color.cgColor(alpha: fillAlpha))
            context.fillEllipse(in: rect)
        }
        context.setStrokeColor(color.cgColor(alpha: 0.95))
        context.setLineWidth(lineWidth)
        context.strokeEllipse(in: rect)

        guard let image = context.makeImage() else { return CIImage.empty() }
        return CIImage(cgImage: image)
    }
}

/// Composition vidéo Core Image : effets (annotations, clics), puis mise à la taille de rendu.
/// Les clics passent par là à la lecture (aperçu fidèle) ; les annotations seulement à l'export
/// (l'éditeur les dessine en SwiftUI, pour qu'elles suivent la souris pendant le tracé).
enum VideoEffects {
    static func videoComposition(
        for asset: UncheckedSendable<AVAsset>,
        clicks: ClickOverlay?,
        annotations: AnnotationOverlay? = nil,
        renderSize: CGSize?,
        frameRate: Double?
    ) async throws -> AVMutableVideoComposition {
        let composition = try await AVMutableVideoComposition.videoComposition(with: asset.value) { request in
            var image = request.sourceImage
            let extent = image.extent
            let time = request.compositionTime.seconds
            // Annotations sous les clics : un clic reste visible dans une zone mise en avant.
            if let annotations {
                image = annotations.apply(to: image, at: time)
            }
            if let clicks {
                image = clicks.apply(to: image, at: time)
            }
            if let renderSize, extent.width > 0, extent.height > 0 {
                image = image.transformed(by: CGAffineTransform(
                    scaleX: renderSize.width / extent.width,
                    y: renderSize.height / extent.height
                ))
            }
            let size = renderSize ?? extent.size
            request.finish(with: image.cropped(to: CGRect(origin: .zero, size: size)), context: nil)
        }
        if let renderSize {
            composition.renderSize = renderSize
        }
        if let frameRate {
            composition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        }
        return composition
    }
}
