import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Sélecteur de zone façon Cmd+Shift+4 : un calque plein écran par moniteur, on glisse pour tracer.
/// Le bouton "Plein écran" du panneau sélectionne l'écran entier.
@MainActor
final class SelectionOverlay {
    private let options: SelectionOptions
    private let microphoneAvailable: Bool
    private let onConfirm: (CaptureRegion) -> Void
    private let onCancel: () -> Void

    private var windows: [OverlayWindow] = []
    private var views: [SelectionView] = []

    init(
        options: SelectionOptions,
        microphoneAvailable: Bool,
        onConfirm: @escaping (CaptureRegion) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.options = options
        self.microphoneAvailable = microphoneAvailable
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    func show(initial: CaptureRegion?) {
        for screen in NSScreen.screens {
            guard let displayID = screen.displayID else { continue }

            let window = OverlayWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.configure(frame: screen.frame)
            window.onKeyDown = { [weak self] event in self?.handleKey(event) ?? false }

            let view = SelectionView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                displayID: displayID,
                scale: screen.backingScaleFactor,
                options: options,
                microphoneAvailable: microphoneAvailable,
                onRecord: { [weak self] in self?.confirm() },
                onCancel: { [weak self] in self?.onCancel() }
            )
            view.overlay = self
            if let initial, initial.displayID == displayID, view.bounds.contains(initial.rect) {
                view.selection = initial.rect
            }
            window.contentView = view

            windows.append(window)
            views.append(view)
        }

        NSApp.activate()
        windows.forEach { $0.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        let target = windows.first { $0.frame.contains(mouse) } ?? windows.first
        target?.makeKey()
        NSCursor.crosshair.set()
    }

    func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        views.removeAll()
    }

    /// Une seule zone à la fois : tracer sur un écran efface la sélection des autres.
    func selectionBegan(on view: SelectionView) {
        for other in views where other !== view && other.selection != nil {
            other.selection = nil
        }
        view.window?.makeKey()
    }

    private func confirm() {
        guard let view = views.first(where: { $0.selection != nil }), let selection = view.selection else { return }
        onConfirm(CaptureRegion(displayID: view.displayID, rect: selection))
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onCancel()
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            confirm()
            return true
        default:
            return false
        }
    }
}

final class OverlayWindow: NSPanel {
    var onKeyDown: ((NSEvent) -> Bool)?

    func configure(frame: CGRect) {
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(frame, display: false)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if onKeyDown?(event) != true {
            super.keyDown(with: event)
        }
    }
}

final class SelectionView: NSView {
    weak var overlay: SelectionOverlay?
    let displayID: CGDirectDisplayID
    private let scale: CGFloat
    private let controlsState = SelectionControlsState()
    private var controls: NSHostingView<SelectionControls>!

    private static let minimumSize: CGFloat = 10
    /// Distance en dessous de laquelle un bord de la zone se colle au bord de l'écran.
    private static let snapDistance: CGFloat = 8
    private static let edgeThickness: CGFloat = 4

    /// Dernière zone hors plein écran, restaurée quand on quitte le plein écran.
    private var windowedSelection: CGRect?

    /// Zone sélectionnée, en points, origine en haut à gauche (la vue est retournée).
    var selection: CGRect? {
        didSet {
            controlsState.hasSelection = selection != nil
            controlsState.isFullScreen = isFullScreen
            needsDisplay = true
            layoutControls()
            window?.invalidateCursorRects(for: self)
        }
    }

    private var isFullScreen: Bool { selection == bounds }

    private enum Drag {
        case creating(origin: CGPoint)
        case moving(start: CGPoint, rect: CGRect)
        case resizing(Handle, start: CGPoint, rect: CGRect)
    }

    private var drag: Drag?

    init(
        frame: CGRect,
        displayID: CGDirectDisplayID,
        scale: CGFloat,
        options: SelectionOptions,
        microphoneAvailable: Bool,
        onRecord: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.displayID = displayID
        self.scale = scale
        super.init(frame: frame)

        controls = ArrowCursorHostingView(rootView: SelectionControls(
            options: options,
            state: controlsState,
            microphoneAvailable: microphoneAvailable,
            onToggleFullScreen: { [weak self] in self?.toggleFullScreen() },
            onRecord: onRecord,
            onCancel: onCancel
        ))
        addSubview(controls)
        layoutControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func toggleFullScreen() {
        if isFullScreen {
            // Une zone déjà collée à un bord donnerait l'impression de rester en plein écran : on repart de la zone par défaut.
            if let windowedSelection, !touchesAnyEdge(windowedSelection) {
                selection = windowedSelection
            } else {
                selection = bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2).integral
            }
        } else {
            rememberWindowedSelection()
            overlay?.selectionBegan(on: self)
            selection = bounds
        }
    }

    private func rememberWindowedSelection() {
        if let selection, !isFullScreen {
            windowedSelection = selection
        }
    }

    // MARK: - Souris

    override func mouseDown(with event: NSEvent) {
        rememberWindowedSelection()
        let point = convert(event.locationInWindow, from: nil)
        if let selection, let handle = Handle.allCases.first(where: { $0.hitRect(in: selection).contains(point) }) {
            drag = .resizing(handle, start: point, rect: selection)
        } else if let selection, !isFullScreen, selection.contains(point) {
            drag = .moving(start: point, rect: selection)
        } else {
            // La sélection actuelle reste affichée tant qu'on n'a pas vraiment commencé à glisser.
            drag = .creating(origin: point)
        }
        layoutControls()
    }

    override func mouseDragged(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        switch drag {
        case .creating(let origin):
            let rect = CGRect(
                x: min(origin.x, point.x),
                y: min(origin.y, point.y),
                width: abs(point.x - origin.x),
                height: abs(point.y - origin.y)
            )
            guard rect.width >= Self.minimumSize || rect.height >= Self.minimumSize else { return }
            overlay?.selectionBegan(on: self)
            selection = snappedEdges(rect)
        case .moving(let start, let rect):
            var moved = rect.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
            moved.origin.x = min(max(moved.minX, bounds.minX), bounds.maxX - moved.width)
            moved.origin.y = min(max(moved.minY, bounds.minY), bounds.maxY - moved.height)
            selection = snappedPosition(moved)
        case .resizing(let handle, let start, let rect):
            let resized = snappedEdges(
                handle.resize(rect, dx: point.x - start.x, dy: point.y - start.y).intersection(bounds)
            )
            if resized.width >= Self.minimumSize && resized.height >= Self.minimumSize {
                selection = resized
            }
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        drag = nil
        if var selection {
            // Garantit une taille minimale, pour que la zone reste toujours attrapable.
            selection.size.width = max(selection.width, Self.minimumSize)
            selection.size.height = max(selection.height, Self.minimumSize)
            selection.origin.x = min(selection.minX, bounds.maxX - selection.width)
            selection.origin.y = min(selection.minY, bounds.maxY - selection.height)
            self.selection = selection.integral.intersection(bounds)
        }
        layoutControls()
        needsDisplay = true
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
    }

    /// Colle chaque bord proche du bord de l'écran (tracé et redimensionnement).
    private func snappedEdges(_ rect: CGRect) -> CGRect {
        var minX = rect.minX, minY = rect.minY, maxX = rect.maxX, maxY = rect.maxY
        if minX - bounds.minX < Self.snapDistance { minX = bounds.minX }
        if minY - bounds.minY < Self.snapDistance { minY = bounds.minY }
        if bounds.maxX - maxX < Self.snapDistance { maxX = bounds.maxX }
        if bounds.maxY - maxY < Self.snapDistance { maxY = bounds.maxY }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Colle la zone au bord de l'écran sans changer sa taille (déplacement).
    private func snappedPosition(_ rect: CGRect) -> CGRect {
        var rect = rect
        if rect.minX - bounds.minX < Self.snapDistance {
            rect.origin.x = bounds.minX
        } else if bounds.maxX - rect.maxX < Self.snapDistance {
            rect.origin.x = bounds.maxX - rect.width
        }
        if rect.minY - bounds.minY < Self.snapDistance {
            rect.origin.y = bounds.minY
        } else if bounds.maxY - rect.maxY < Self.snapDistance {
            rect.origin.y = bounds.maxY - rect.height
        }
        return rect
    }

    /// Côtés de la zone collés au bord de l'écran. Les quatre à la fois = plein écran.
    private func touchingEdges(of rect: CGRect) -> (left: Bool, top: Bool, right: Bool, bottom: Bool) {
        (rect.minX <= bounds.minX, rect.minY <= bounds.minY, rect.maxX >= bounds.maxX, rect.maxY >= bounds.maxY)
    }

    private func touchesAnyEdge(_ rect: CGRect) -> Bool {
        let edges = touchingEdges(of: rect)
        return edges.left || edges.top || edges.right || edges.bottom
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        guard let selection else { return }
        if !isFullScreen {
            addCursorRect(selection, cursor: .openHand)
        }
        for handle in Handle.allCases {
            addCursorRect(handle.hitRect(in: selection), cursor: handle.cursor)
        }
    }

    // MARK: - Contrôles

    /// Sous la zone si elle existe, sinon (ou en plein écran) centré en bas de l'écran. Masqué pendant un tracé.
    private func layoutControls() {
        guard let controls else { return }
        if drag != nil {
            controls.isHidden = true
            return
        }
        let size = controls.fittingSize
        let margin: CGFloat = 12
        var origin = CGPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 80)

        if let selection, !isFullScreen {
            var y = selection.maxY + margin
            if y + size.height > bounds.maxY - margin {
                y = selection.minY - margin - size.height
                if y < bounds.minY + margin {
                    y = selection.maxY - size.height - margin * 2
                }
            }
            let x = min(max(selection.midX - size.width / 2, margin), bounds.maxX - size.width - margin)
            origin = CGPoint(x: x, y: y)
        }

        controls.frame = CGRect(origin: origin, size: size)
        controls.isHidden = false
        window?.invalidateCursorRects(for: controls)
    }

    // MARK: - Dessin

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSBezierPath(rect: bounds)
        if let selection {
            dim.append(NSBezierPath(rect: selection))
            dim.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.35).setFill()
        dim.fill()

        guard let selection else {
            drawHint()
            return
        }

        // Remplissage quasi invisible : sans lui, les clics dans la zone traverseraient la fenêtre.
        NSColor.black.withAlphaComponent(0.01).setFill()
        selection.fill()

        let accent = NSColor(Theme.accent)
        accent.setStroke()
        let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        // Les côtés collés au bord de l'écran sont surlignés en épais, à l'intérieur de la zone.
        let edges = touchingEdges(of: selection)
        let thickness = Self.edgeThickness
        var handleArea = selection
        accent.setFill()
        if edges.left {
            CGRect(x: selection.minX, y: selection.minY, width: thickness, height: selection.height).fill()
            handleArea.origin.x += thickness
            handleArea.size.width -= thickness
        }
        if edges.right {
            CGRect(x: selection.maxX - thickness, y: selection.minY, width: thickness, height: selection.height).fill()
            handleArea.size.width -= thickness
        }
        if edges.top {
            CGRect(x: selection.minX, y: selection.minY, width: selection.width, height: thickness).fill()
            handleArea.origin.y += thickness
            handleArea.size.height -= thickness
        }
        if edges.bottom {
            CGRect(x: selection.minX, y: selection.maxY - thickness, width: selection.width, height: thickness).fill()
            handleArea.size.height -= thickness
        }

        if case .creating = drag {} else {
            for handle in Handle.allCases {
                let rect = handle.drawRect(in: handleArea)
                NSColor.white.setFill()
                rect.fill()
                accent.setStroke()
                NSBezierPath(rect: rect).stroke()
            }
        }

        let pixels = "\(Int(selection.width * scale)) × \(Int(selection.height * scale))"
        if isFullScreen {
            let text = "Plein écran · \(pixels)"
            let size = (text as NSString).size(withAttributes: Self.labelAttributes(size: 12))
            drawLabel(text, at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 40))
        } else {
            drawLabel(pixels, at: CGPoint(x: selection.minX, y: selection.minY - 26), fallbackInside: selection)
        }
    }

    private func drawHint() {
        let text = "Glisse pour sélectionner une zone · Esc pour annuler"
        let attributes = Self.labelAttributes(size: 14)
        let size = (text as NSString).size(withAttributes: attributes)
        drawLabel(text, at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), size: 14)
    }

    private func drawLabel(_ text: String, at point: CGPoint, size: CGFloat = 12, fallbackInside: CGRect? = nil) {
        let attributes = Self.labelAttributes(size: size)
        let textSize = (text as NSString).size(withAttributes: attributes)
        var origin = point
        if let fallbackInside, origin.y < bounds.minY + 4 {
            origin = CGPoint(x: fallbackInside.minX + 8, y: fallbackInside.minY + 8)
        }
        let background = CGRect(origin: origin, size: textSize).insetBy(dx: -8, dy: -4)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: background, xRadius: 5, yRadius: 5).fill()
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    private static func labelAttributes(size: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
    }
}

/// Affiche la flèche classique au survol, au lieu de la croix du calque de sélection.
private final class ArrowCursorHostingView<Content: View>: NSHostingView<Content> {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

/// Poignées de redimensionnement (coordonnées retournées : y vers le bas).
private enum Handle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    private func point(in rect: CGRect) -> CGPoint {
        switch self {
        case .topLeft: CGPoint(x: rect.minX, y: rect.minY)
        case .top: CGPoint(x: rect.midX, y: rect.minY)
        case .topRight: CGPoint(x: rect.maxX, y: rect.minY)
        case .right: CGPoint(x: rect.maxX, y: rect.midY)
        case .bottomRight: CGPoint(x: rect.maxX, y: rect.maxY)
        case .bottom: CGPoint(x: rect.midX, y: rect.maxY)
        case .bottomLeft: CGPoint(x: rect.minX, y: rect.maxY)
        case .left: CGPoint(x: rect.minX, y: rect.midY)
        }
    }

    func drawRect(in rect: CGRect) -> CGRect {
        let p = point(in: rect)
        return CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
    }

    func hitRect(in rect: CGRect) -> CGRect {
        let p = point(in: rect)
        return CGRect(x: p.x - 8, y: p.y - 8, width: 16, height: 16)
    }

    func resize(_ rect: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        switch self {
        case .topLeft, .left, .bottomLeft: minX += dx
        case .topRight, .right, .bottomRight: maxX += dx
        case .top, .bottom: break
        }
        switch self {
        case .topLeft, .top, .topRight: minY += dy
        case .bottomLeft, .bottom, .bottomRight: maxY += dy
        case .left, .right: break
        }
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    var cursor: NSCursor {
        let position: NSCursor.FrameResizePosition = switch self {
        case .topLeft: .topLeft
        case .top: .top
        case .topRight: .topRight
        case .right: .right
        case .bottomRight: .bottomRight
        case .bottom: .bottom
        case .bottomLeft: .bottomLeft
        case .left: .left
        }
        return .frameResize(position: position, directions: .all)
    }
}
