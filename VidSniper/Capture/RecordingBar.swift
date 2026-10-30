import AppKit
import SwiftUI

/// Pendant l'enregistrement : un cadre autour de la zone, une poignée pour la déplacer, et une mini barre
/// (chrono, pause, stop). Tout est exclu de la vidéo, car les fenêtres de l'app sont filtrées par le Recorder.
@MainActor
final class RecordingBarController {
    private let bar: NSPanel
    private let frame: NSPanel
    private let grip: NSPanel
    private let screen: NSScreen
    private var region: CaptureRegion
    private var dragStartRect: CGRect?
    private var dragStartBarOrigin: CGPoint?
    private let onMove: (CaptureRegion) -> Void

    private static let gripSize = CGSize(width: 28, height: 28)

    init(
        region: CaptureRegion,
        session: RecordingSession,
        onTogglePause: @escaping () -> Void,
        onStop: @escaping () -> Void,
        onMove: @escaping (CaptureRegion) -> Void
    ) {
        self.region = region
        self.onMove = onMove
        screen = region.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let target = region.globalRect(on: screen)

        frame = Self.makePanel(rect: .zero)
        frame.ignoresMouseEvents = true
        frame.contentView = RegionBorderView()

        grip = Self.makePanel(rect: CGRect(origin: .zero, size: Self.gripSize))
        let gripView = GripView()
        grip.contentView = gripView

        let content = NSHostingView(rootView: RecordingBarView(
            session: session,
            onTogglePause: onTogglePause,
            onStop: onStop
        ))
        let size = content.fittingSize
        bar = Self.makePanel(rect: Self.barRect(size: size, around: target, in: screen.visibleFrame))
        bar.contentView = content
        bar.isMovableByWindowBackground = true
        bar.hasShadow = true

        gripView.onDrag = { [weak self] delta in self?.drag(by: delta) }
        gripView.onDragEnded = { [weak self] in
            self?.dragStartRect = nil
            self?.dragStartBarOrigin = nil
        }
        layoutRegionPanels()
    }

    func show() {
        frame.orderFrontRegardless()
        grip.orderFrontRegardless()
        bar.orderFrontRegardless()
    }

    func close() {
        frame.orderOut(nil)
        grip.orderOut(nil)
        bar.orderOut(nil)
    }

    // MARK: - Déplacement de la zone

    /// `delta` : déplacement de la souris depuis le début du glisser, en coordonnées globales (y vers le haut).
    private func drag(by delta: CGSize) {
        let start = dragStartRect ?? region.rect
        dragStartRect = start
        let barStart = dragStartBarOrigin ?? bar.frame.origin
        dragStartBarOrigin = barStart

        var rect = start.offsetBy(dx: delta.width, dy: -delta.height)
        rect.origin.x = min(max(rect.minX, 0), screen.frame.width - rect.width).rounded()
        rect.origin.y = min(max(rect.minY, 0), screen.frame.height - rect.height).rounded()
        guard rect != region.rect else { return }

        region = CaptureRegion(displayID: region.displayID, rect: rect)
        layoutRegionPanels()

        // La mini barre suit la zone (déplacement réel, une fois la zone bloquée par les bords de l'écran).
        let applied = CGSize(width: rect.minX - start.minX, height: start.minY - rect.minY)
        var barOrigin = CGPoint(x: barStart.x + applied.width, y: barStart.y + applied.height)
        let visible = screen.visibleFrame
        barOrigin.x = min(max(barOrigin.x, visible.minX), visible.maxX - bar.frame.width)
        barOrigin.y = min(max(barOrigin.y, visible.minY), visible.maxY - bar.frame.height)
        bar.setFrameOrigin(barOrigin)

        onMove(region)
    }

    private func layoutRegionPanels() {
        let target = region.globalRect(on: screen)
        frame.setFrame(target.insetBy(dx: -3, dy: -3), display: true)

        // Poignée au-dessus du coin haut gauche, ou à l'intérieur si la zone touche le haut de l'écran.
        var origin = CGPoint(x: target.minX - 3, y: target.maxY + 6)
        if origin.y + Self.gripSize.height > screen.frame.maxY {
            origin = CGPoint(x: target.minX + 6, y: target.maxY - 6 - Self.gripSize.height)
        }
        grip.setFrameOrigin(origin)

        // En plein écran, il n'y a rien à déplacer.
        let isFullScreen = region.rect.size == screen.frame.size
        grip.alphaValue = isFullScreen ? 0 : 1
        grip.ignoresMouseEvents = isFullScreen
    }

    // MARK: - Fenêtres

    private static func makePanel(rect: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    /// Sous la zone si possible, sinon au-dessus, sinon à l'intérieur en bas (cas de l'écran entier).
    private static func barRect(size: CGSize, around target: CGRect, in visible: CGRect) -> CGRect {
        let margin: CGFloat = 10
        var y = target.minY - margin - size.height
        if y < visible.minY {
            y = target.maxY + margin
            if y + size.height > visible.maxY {
                y = max(target.minY, visible.minY) + margin * 2
            }
        }
        let x = min(max(target.midX - size.width / 2, visible.minX + margin), visible.maxX - size.width - margin)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }
}

private final class RegionBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        path.lineWidth = 2
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor(Theme.accent).setStroke()
        path.stroke()
    }
}

/// Poignée à glisser pour déplacer la zone enregistrée.
private final class GripView: NSView {
    var onDrag: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    private var dragStart: CGPoint?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Pendant l'enregistrement, l'app est en arrière-plan : les cursor rects ne s'appliquent pas,
    // on suit donc la souris avec une tracking area active en permanence.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseMoved(with event: NSEvent) {
        if dragStart == nil { NSCursor.openHand.set() }
    }

    override func mouseExited(with event: NSEvent) {
        if dragStart == nil { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        dragStart = NSEvent.mouseLocation
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let location = NSEvent.mouseLocation
        onDrag?(CGSize(width: location.x - dragStart.x, height: location.y - dragStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        dragStart = nil
        NSCursor.openHand.set()
        onDragEnded?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor(Theme.accent).setFill()
        background.fill()

        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let symbol = NSImage(
            systemSymbolName: "arrow.up.and.down.and.arrow.left.and.right",
            accessibilityDescription: "Déplacer la zone"
        )?.withSymbolConfiguration(configuration) else { return }
        let size = symbol.size
        symbol.draw(in: CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        ))
    }
}

private struct RecordingBarView: View {
    let session: RecordingSession
    let onTogglePause: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(session.isPaused ? Theme.textMuted : Theme.error)
                .frame(width: 8, height: 8)

            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                Text(Self.format(session.elapsed(at: context.date)))
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textNormal)
                    .frame(minWidth: 44, alignment: .leading)
            }

            Button(action: onTogglePause) {
                Image(systemName: session.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(IconButtonStyle())
            .help(session.isPaused ? "Reprendre" : "Pause")

            Button(action: onStop) {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(IconButtonStyle(tint: Theme.error))
            .help("Arrêter (\(AppCoordinator.shortcutLabel))")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.backgroundPrimary))
        .overlay(Capsule().stroke(Theme.border, lineWidth: 1))
        .padding(1)
        .fixedSize()
    }

    private static func format(_ interval: TimeInterval) -> String {
        let seconds = Int(interval)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
