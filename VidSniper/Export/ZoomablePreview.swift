import AppKit
import SwiftUI

/// Contenu SwiftUI dans une vue défilante zoomable (pincement autour du pointeur, défilement à deux doigts),
/// centré tant qu'il est plus petit que la zone. Zoom 1 = `contentSize` points.
struct ZoomablePreview<Content: View>: NSViewRepresentable {
    let contentSize: CGSize
    /// `nil` : ajusté à la zone.
    let zoom: Double?
    let range: ClosedRange<Double>
    /// Zoom qui ajuste le contenu à la zone, à chaque changement de taille.
    let onFitZoomChange: (Double) -> Void
    /// Zoom recalculé quand la taille du contenu change (autre définition), pour garder le même cadrage.
    let onZoomRescaled: (Double) -> Void
    /// Zoom choisi au pincement, à chaque étape du geste.
    let onPinch: (Double) -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView()
        scrollView.contentView = CenteringClipView()
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.allowsMagnification = true
        let hostingView = NSHostingView(rootView: content())
        // La taille vient du zoom, pas du contenu SwiftUI.
        hostingView.sizingOptions = []
        scrollView.documentView = hostingView

        let coordinator = context.coordinator
        coordinator.scrollView = scrollView
        scrollView.onLayout = { [weak coordinator] in coordinator?.apply() }
        scrollView.onMagnify = { [weak coordinator] in coordinator?.reportPinch() }
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.willStartPinch),
            name: NSScrollView.willStartLiveMagnifyNotification, object: scrollView
        )
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.didEndPinch),
            name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: ZoomScrollView, context: Context) {
        (scrollView.documentView as? NSHostingView<Content>)?.rootView = content()
        let coordinator = context.coordinator
        coordinator.contentSize = contentSize
        coordinator.setRequestedZoom(zoom)
        coordinator.range = range
        coordinator.onFitZoomChange = onFitZoomChange
        coordinator.onZoomRescaled = onZoomRescaled
        coordinator.onPinch = onPinch
        coordinator.apply()
    }

    @MainActor
    final class Coordinator: NSObject {
        weak var scrollView: ZoomScrollView?
        var contentSize: CGSize = .zero
        var zoom: Double?
        var range: ClosedRange<Double> = 0.1...8
        var onFitZoomChange: ((Double) -> Void)?
        var onZoomRescaled: ((Double) -> Void)?
        var onPinch: ((Double) -> Void)?
        private var isPinching = false
        private var reportedFitZoom: Double?
        /// Point visible au centre, en proportion du contenu, à garder quand la taille du contenu change
        /// (autre taille d'export).
        private var centerToRestore: CGPoint?
        /// Zoom recalculé pas encore revenu de l'éditeur : l'ancien, encore reçu entre-temps, est ignoré.
        private var pendingRescale: (from: Double, to: Double)?

        func setRequestedZoom(_ requested: Double?) {
            if let pending = pendingRescale {
                if requested == pending.from { return }
                pendingRescale = nil
            }
            zoom = requested
        }

        /// Taille du contenu, bornes et zoom demandé appliqués à la vue défilante.
        func apply() {
            guard let scrollView, let documentView = scrollView.documentView,
                  contentSize.width > 0, contentSize.height > 0 else { return }
            let previousSize = documentView.frame.size
            if previousSize != contentSize {
                if previousSize.width > 0, previousSize.height > 0 {
                    let visible = scrollView.contentView.bounds
                    centerToRestore = CGPoint(x: visible.midX / previousSize.width, y: visible.midY / previousSize.height)
                    // Même taille à l'écran : la vidéo en Retina, deux fois plus grande, prend deux fois moins de zoom.
                    if let zoom {
                        let rescaled = zoom * previousSize.width / contentSize.width
                        pendingRescale = (zoom, rescaled)
                        self.zoom = rescaled
                        let report = onZoomRescaled
                        DispatchQueue.main.async { report?(rescaled) }
                    }
                }
                documentView.setFrameSize(contentSize)
            }

            let area = scrollView.contentSize
            guard area.width > 0, area.height > 0 else { return }
            let fit = min(area.width / contentSize.width, area.height / contentSize.height)
            if reportedFitZoom.map({ abs($0 - fit) > 0.0001 }) ?? true {
                reportedFitZoom = fit
                // Pas pendant la mise à jour des vues SwiftUI.
                let report = onFitZoomChange
                DispatchQueue.main.async { report?(fit) }
            }

            scrollView.minMagnification = max(min(fit, 1), range.lowerBound)
            scrollView.maxMagnification = max(fit, range.upperBound)
            // Pendant un pincement, le zoom affiché fait foi : la lecture redessine les vues à chaque image.
            guard !isPinching else { return }
            let target = zoom ?? fit
            if abs(scrollView.magnification - target) > 0.0001 {
                let visible = scrollView.contentView.bounds
                scrollView.setMagnification(target, centeredAt: CGPoint(x: visible.midX, y: visible.midY))
            }
            if let center = centerToRestore {
                centerToRestore = nil
                scroll(toCenter: CGPoint(x: center.x * contentSize.width, y: center.y * contentSize.height))
            }
        }

        private func scroll(toCenter center: CGPoint) {
            guard let scrollView else { return }
            let clipView = scrollView.contentView
            let size = clipView.bounds.size
            let proposed = NSRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            clipView.setBoundsOrigin(clipView.constrainBoundsRect(proposed).origin)
            scrollView.reflectScrolledClipView(clipView)
        }

        @objc func willStartPinch() {
            isPinching = true
        }

        /// Zoom remonté pendant le geste, pour que le pourcentage suive les doigts.
        func reportPinch() {
            guard let scrollView else { return }
            onPinch?(scrollView.magnification)
        }

        @objc func didEndPinch() {
            isPinching = false
            reportPinch()
        }
    }
}

final class ZoomScrollView: NSScrollView {
    var onLayout: (() -> Void)?
    var onMagnify: (() -> Void)?

    override func magnify(with event: NSEvent) {
        super.magnify(with: event)
        onMagnify?()
    }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// Garde le contenu centré quand il est plus petit que la zone visible.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let content = documentView.frame
        if rect.width > content.width {
            rect.origin.x = content.minX - (rect.width - content.width) / 2
        }
        if rect.height > content.height {
            rect.origin.y = content.minY - (rect.height - content.height) / 2
        }
        return rect
    }
}
