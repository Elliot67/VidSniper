import SwiftUI

/// Calque posé sur la vidéo de l'éditeur : affiche les annotations visibles à la tête de lecture
/// (même rendu que l'export) et permet de les tracer, sélectionner, déplacer et redimensionner.
struct AnnotationLayer: View {
    let document: EditorDocument

    private enum Corner: CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    private enum Interaction {
        case creating(origin: CGPoint)
        case moving(id: UUID, original: CGRect, origin: CGPoint)
        case resizing(id: UUID, original: CGRect, corner: Corner)
    }

    @State private var interaction: Interaction?
    /// Zone en cours de tracé (coordonnées normalisées).
    @State private var draft: CGRect?

    private static let minimumSize: CGFloat = 0.02
    private static let handleSize: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            let video = videoRect(in: geometry.size)
            let time = document.timeMapping.sourceTime(at: document.currentTime)

            Canvas { context, _ in
                draw(in: &context, video: video, time: time)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if interaction == nil {
                            begin(at: normalized(value.startLocation, in: video), time: time)
                        }
                        update(to: normalized(value.location, in: video))
                    }
                    .onEnded { _ in finish() }
            )
            .onContinuousHover { phase in
                if case .active = phase {
                    (document.isDrawingAnnotation ? NSCursor.crosshair : NSCursor.arrow).set()
                }
            }
        }
    }

    // MARK: - Géométrie

    /// Zone occupée par l'image dans la vue (vidéo ajustée sans déformation).
    private func videoRect(in size: CGSize) -> CGRect {
        let aspect = max(document.videoAspectRatio, 0.01)
        var width = size.width
        var height = width / aspect
        if height > size.height {
            height = size.height
            width = height * aspect
        }
        return CGRect(x: (size.width - width) / 2, y: (size.height - height) / 2, width: width, height: height)
    }

    private func normalized(_ point: CGPoint, in video: CGRect) -> CGPoint {
        CGPoint(
            x: min(max((point.x - video.minX) / max(video.width, 1), 0), 1),
            y: min(max((point.y - video.minY) / max(video.height, 1), 0), 1)
        )
    }

    private func viewRect(_ rect: CGRect, in video: CGRect) -> CGRect {
        CGRect(
            x: video.minX + rect.minX * video.width,
            y: video.minY + rect.minY * video.height,
            width: rect.width * video.width,
            height: rect.height * video.height
        )
    }

    private func corner(_ corner: Corner, of rect: CGRect) -> CGPoint {
        switch corner {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    // MARK: - Dessin

    private func draw(in context: inout GraphicsContext, video: CGRect, time: Double?) {
        let visible = document.state.annotations.compactMap { annotation -> (Annotation, Double)? in
            let opacity = time.map { annotation.opacity(atSource: $0) } ?? 0
            return opacity > 0 ? (annotation, opacity) : nil
        }

        // Projecteurs : un seul assombrissement, percé de toutes les zones visibles.
        let spotlights = visible.filter { $0.0.style == .spotlight }
        if let opacity = spotlights.map(\.1).max() {
            var dim = Path(video)
            for (spotlight, _) in spotlights {
                dim.addPath(Path(Annotation.path(spotlight.shape, in: viewRect(spotlight.rect, in: video))))
            }
            context.fill(dim, with: .color(.black.opacity(Annotation.spotlightDim * opacity)), style: FillStyle(eoFill: true))
        }

        // Cadres, avec la même épaisseur relative et la même ombre qu'à l'export.
        let lineWidth = max(1.5, video.width * 0.004)
        for (frame, opacity) in visible where frame.style == .frame {
            var layer = context
            layer.opacity = opacity
            layer.addFilter(.shadow(color: .black.opacity(0.5), radius: lineWidth * 0.75))
            layer.stroke(
                Path(Annotation.path(frame.shape, in: viewRect(frame.rect, in: video))),
                with: .color(frame.color.color),
                lineWidth: lineWidth
            )
        }

        // Annotation sélectionnée : poignées, ou contour en pointillés si elle n'est pas visible à cet instant.
        if let selected = document.selectedAnnotation {
            let rect = viewRect(selected.rect, in: video)
            let isVisible = visible.contains { $0.0.id == selected.id }
            if !isVisible {
                context.stroke(
                    Path(Annotation.path(selected.shape, in: rect)),
                    with: .color(.white.opacity(0.7)),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
            }
            context.stroke(Path(rect), with: .color(Theme.accent.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            for handle in Corner.allCases {
                let point = corner(handle, of: rect)
                let square = CGRect(
                    x: point.x - Self.handleSize / 2, y: point.y - Self.handleSize / 2,
                    width: Self.handleSize, height: Self.handleSize
                )
                context.fill(Path(square), with: .color(.white))
                context.stroke(Path(square), with: .color(Theme.accent), lineWidth: 1.5)
            }
        }

        // Tracé en cours.
        if let draft, document.isDrawingAnnotation {
            let style = document.newAnnotationStyle
            let rect = viewRect(draft, in: video)
            let path = Path(Annotation.path(document.newAnnotationShape, in: rect))
            if style == .spotlight {
                var dim = Path(video)
                dim.addPath(path)
                context.fill(dim, with: .color(.black.opacity(Annotation.spotlightDim)), style: FillStyle(eoFill: true))
            } else {
                context.stroke(path, with: .color(document.newAnnotationColor.color), lineWidth: lineWidth)
            }
        }
    }

    // MARK: - Interaction

    private func begin(at point: CGPoint, time: Double?) {
        if document.isDrawingAnnotation {
            interaction = .creating(origin: point)
            return
        }

        // Poignée de l'annotation sélectionnée (tolérance d'environ 2 % de l'image).
        if let selected = document.selectedAnnotation,
           let handle = Corner.allCases.first(where: { handle in
               let target = corner(handle, of: selected.rect)
               return abs(target.x - point.x) < 0.02 && abs(target.y - point.y) < 0.03
           }) {
            document.beginAnnotationEdit()
            interaction = .resizing(id: selected.id, original: selected.rect, corner: handle)
            return
        }

        // Annotation visible sous la souris (la dernière tracée est au-dessus), ou la sélectionnée.
        let candidates = document.state.annotations.filter { annotation in
            annotation.id == document.selectedAnnotationID || (time.map { annotation.opacity(atSource: $0) > 0 } ?? false)
        }
        if let hit = candidates.last(where: { $0.rect.contains(point) }) {
            document.selectedAnnotationID = hit.id
            document.selectedSegment = nil
            document.beginAnnotationEdit()
            interaction = .moving(id: hit.id, original: hit.rect, origin: point)
            return
        }

        document.selectedAnnotationID = nil
    }

    private func update(to point: CGPoint) {
        switch interaction {
        case .creating(let origin):
            draft = CGRect(
                x: min(origin.x, point.x),
                y: min(origin.y, point.y),
                width: abs(point.x - origin.x),
                height: abs(point.y - origin.y)
            )
        case .moving(let id, let original, let origin):
            var rect = original.offsetBy(dx: point.x - origin.x, dy: point.y - origin.y)
            rect.origin.x = min(max(rect.minX, 0), 1 - rect.width)
            rect.origin.y = min(max(rect.minY, 0), 1 - rect.height)
            document.editAnnotation(id) { $0.rect = rect }
        case .resizing(let id, let original, let handle):
            // Le coin opposé reste fixe.
            let fixed: CGPoint = switch handle {
            case .topLeft: CGPoint(x: original.maxX, y: original.maxY)
            case .topRight: CGPoint(x: original.minX, y: original.maxY)
            case .bottomLeft: CGPoint(x: original.maxX, y: original.minY)
            case .bottomRight: CGPoint(x: original.minX, y: original.minY)
            }
            let rect = CGRect(
                x: min(fixed.x, point.x),
                y: min(fixed.y, point.y),
                width: max(abs(point.x - fixed.x), Self.minimumSize),
                height: max(abs(point.y - fixed.y), Self.minimumSize)
            )
            document.editAnnotation(id) { $0.rect = rect }
        case nil:
            break
        }
    }

    private func finish() {
        switch interaction {
        case .creating:
            if let draft, draft.width >= Self.minimumSize, draft.height >= Self.minimumSize {
                document.createAnnotation(in: draft)
            }
        case .moving, .resizing:
            document.endAnnotationEdit()
        case nil:
            break
        }
        interaction = nil
        draft = nil
    }
}
