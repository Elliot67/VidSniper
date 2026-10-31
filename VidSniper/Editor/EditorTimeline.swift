import AppKit
import Observation
import SwiftUI

/// État de défilement de la timeline, partagé avec le moniteur d'événements du trackpad.
/// Le pincement et le glisser vertical sont interceptés en AppKit : la ScrollView les garde pour elle sinon.
@MainActor
@Observable
final class TimelineScroller {
    var position = ScrollPosition(edge: .leading)
    var visibleOffset: CGFloat = 0
    var visibleWidth: CGFloat = 0
    var contentWidth: CGFloat = 0
    /// Cadre de la zone défilante, en coordonnées globales de la fenêtre (origine en haut à gauche).
    var viewportFrame: CGRect = .zero
    var leadingMargin: CGFloat = 0
    /// Instant et position à l'écran à garder fixes au prochain zoom (sinon : la tête de lecture).
    @ObservationIgnored var zoomAnchor: (time: Double, screenX: CGFloat)?
    @ObservationIgnored private var monitor: Any?

    func install(document: EditorDocument) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self, weak document] event in
            // Les moniteurs locaux sont appelés sur le thread principal.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated {
                guard let self, let document else { return false }
                return self.handle(event, document: document)
            }
            return handled ? nil : event
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func handle(_ event: NSEvent, document: EditorDocument) -> Bool {
        guard let content = event.window?.contentView else { return false }
        let location = event.locationInWindow
        let point = CGPoint(x: location.x, y: content.frame.height - location.y)
        guard viewportFrame.contains(point) else { return false }

        switch event.type {
        case .magnify:
            // Pincement : zoom autour du point sous les doigts.
            let scale = document.scale
            let screenX = point.x - viewportFrame.minX
            zoomAnchor = ((visibleOffset + screenX - leadingMargin) / scale, screenX)
            document.setScale(scale * (1 + event.magnification))
            return true
        case .scrollWheel:
            // Glisser vertical à deux doigts (ou molette) : défilement horizontal de la timeline.
            guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return false }
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 10
            let offset = min(max(visibleOffset - delta, 0), max(0, contentWidth - visibleWidth))
            visibleOffset = offset
            position.scrollTo(x: offset)
            return true
        default:
            return false
        }
    }
}

/// Timeline du montage : colonne de libellés (avec les interrupteurs audio) et zone défilante avec
/// règle, vignettes, une ligne de niveau sonore par piste, segments et tête de lecture.
struct EditorTimeline: View {
    let document: EditorDocument

    /// Échelle (points par seconde) au début d'un rognage.
    @State private var trimScale: Double?
    @State private var scroller = TimelineScroller()

    /// Rognage en cours : de quoi recalculer l'aperçu quand la timeline défile toute seule.
    private struct TrimDrag {
        let index: Int
        let edge: SegmentEdge
        let startOffset: CGFloat
        var translation: CGFloat
        var locationX: CGFloat
    }

    @State private var trimDrag: TrimDrag?
    @State private var autoScrollTask: Task<Void, Never>?
    private static let autoScrollZone: CGFloat = 40

    private static let rulerHeight: CGFloat = 18
    private static let thumbnailHeight: CGFloat = 56
    private static let laneHeight: CGFloat = 30
    private static let rowSpacing: CGFloat = 2
    private static let handleWidth: CGFloat = 10
    private static let headerWidth: CGFloat = 156
    private static let minimumMargin: CGFloat = 12

    private enum Lane: Hashable {
        case systemAudio, microphone
    }

    /// Ce qui fait bouger le contenu sous la tête de lecture : zoom et marge de gauche.
    private struct Layout: Equatable {
        let scale: Double
        let leadingMargin: CGFloat
    }

    private var lanes: [Lane] {
        var lanes: [Lane] = []
        if document.hasSystemAudioTrack { lanes.append(.systemAudio) }
        if document.hasMicrophoneTrack { lanes.append(.microphone) }
        return lanes
    }

    /// Hauteur des lignes couvertes par les segments (vignettes + son).
    private var tracksHeight: CGFloat {
        Self.thumbnailHeight + CGFloat(lanes.count) * (Self.laneHeight + Self.rowSpacing)
    }

    private var contentHeight: CGFloat {
        Self.rulerHeight + Self.rowSpacing + tracksHeight
    }

    /// Place réservée avant le montage : de quoi rallonger vers la gauche n'importe quel clip rogné,
    /// même un clip du milieu dont la partie disponible dépasse le début de la timeline.
    private func leadingMargin(scale: Double) -> CGFloat {
        let starts = document.segmentStarts
        let overhang = document.state.segments.enumerated().map { index, segment in
            (segment.range.start.seconds - segment.limit.start.seconds - starts[index]) * scale
        }.max() ?? 0
        return Self.minimumMargin + max(0, overhang)
    }

    /// Place réservée après le montage : de quoi rallonger vers la droite n'importe quel clip rogné.
    private func trailingMargin(scale: Double) -> CGFloat {
        let starts = document.segmentStarts
        let duration = document.duration
        let overhang = document.state.segments.enumerated().map { index, segment in
            let end = starts[index] + segment.range.duration.seconds
            return (end + segment.limit.end.seconds - segment.range.end.seconds - duration) * scale
        }.max() ?? 0
        return Self.minimumMargin + max(0, overhang)
    }

    var body: some View {
        let scale = document.scale
        let leading = leadingMargin(scale: scale)

        HStack(alignment: .top, spacing: 8) {
            header

            GeometryReader { geometry in
                let timelineWidth = document.duration * scale
                let contentWidth = max(geometry.size.width, leading + timelineWidth + trailingMargin(scale: scale))

                ScrollView(.horizontal) {
                    content(width: contentWidth, leading: leading, timelineWidth: timelineWidth, scale: scale)
                }
                .scrollPosition(Binding(get: { scroller.position }, set: { scroller.position = $0 }))
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.x }) { _, offset in
                    scroller.visibleOffset = offset
                }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame in
                    scroller.viewportFrame = frame
                }
                .onAppear {
                    scroller.visibleWidth = geometry.size.width
                    scroller.contentWidth = contentWidth
                    scroller.leadingMargin = leading
                    scroller.install(document: document)
                    document.setViewportWidth(geometry.size.width - 2 * Self.minimumMargin)
                }
                .onDisappear {
                    scroller.uninstall()
                }
                .onChange(of: contentWidth) { _, width in
                    scroller.contentWidth = width
                }
                .onChange(of: geometry.size.width) { _, width in
                    scroller.visibleWidth = width
                    document.setViewportWidth(width - 2 * Self.minimumMargin)
                }
            }
            .frame(height: contentHeight + 10)
            .background(Theme.backgroundPrimary)
        }
        .onChange(of: document.currentTime) { _, time in
            followPlayhead(time, leading: leading, scale: scale)
        }
        .onChange(of: Layout(scale: scale, leadingMargin: leading)) { old, new in
            scroller.leadingMargin = new.leadingMargin
            keepInPlace(from: old, to: new)
        }
        .onChange(of: document.fitRequest) {
            // Après la mise à jour du zoom (et de son recalage), on cadre le début du montage.
            Task { @MainActor in
                await Task.yield()
                scroller.position.scrollTo(x: max(0, leadingMargin(scale: document.scale) - Self.minimumMargin))
            }
        }
    }

    // MARK: - Colonne de libellés

    private var header: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            Color.clear.frame(height: Self.rulerHeight)

            Label("Vidéo", systemImage: "film")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textMuted)
                .frame(height: Self.thumbnailHeight)

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ForEach(lanes, id: \.self) { lane in
                        laneChip(lane)
                            .focusable(false)
                            .frame(height: Self.laneHeight)
                    }
                }
                Spacer(minLength: 0)
                // Balance entre les deux lignes de son : en haut la première piste ressort, en bas la seconde (la voix).
                if lanes.count == 2 {
                    BalanceSlider(
                        value: Binding(get: { document.balance }, set: { document.balance = $0 }),
                        defaultValue: EditorDocument.defaultBalance,
                        isEnabled: document.isBalanceAvailable
                    )
                    .frame(width: 16, height: 2 * Self.laneHeight + Self.rowSpacing)
                    .help(balanceHelp)
                }
            }
        }
        .frame(width: Self.headerWidth, alignment: .leading)
    }

    /// Libellé d'une piste ("Son système"/"Micro", ou "Audio 1"/"Audio 2" pour une vidéo importée).
    private func title(_ lane: Lane) -> String {
        document.recording.audioTitle(microphone: lane == .microphone)
    }

    private func laneChip(_ lane: Lane) -> some View {
        let isMicrophone = lane == .microphone
        let icons = document.recording.audioIcons(microphone: isMicrophone)
        let name = title(lane)
        return ToggleChip(
            isOn: Binding(
                get: { isMicrophone ? document.state.microphone : document.state.systemAudio },
                set: { isMicrophone ? document.setMicrophone($0) : document.setSystemAudio($0) }
            ),
            title: name,
            onIcon: icons.on,
            offIcon: icons.off
        )
        .help(document.isSilent(microphone: isMicrophone)
            ? "Pas de son détecté (\(name))"
            : "Garder ou couper la piste \(name)")
    }

    private var balanceHelp: String {
        let top = title(.systemAudio)
        let bottom = title(.microphone)
        if document.isSilent(microphone: true) { return "Balance indisponible : pas de son détecté (\(bottom))" }
        if document.isSilent(microphone: false) { return "Balance indisponible : pas de son détecté (\(top))" }
        guard document.isBalanceAvailable else { return "Balance : il faut garder les deux pistes" }
        let offset = Int((abs(document.balance) * EditorDocument.balanceRange).rounded())
        if offset == 0 { return "Balance : \(bottom) et \(top) au même niveau (double-clic : réglage par défaut)" }
        let quieter = document.balance < 0 ? top : bottom
        return "Balance : \(quieter) \(offset) dB plus bas (double-clic : réglage par défaut)"
    }

    /// Gain réellement appliqué à la piste (normalisation + balance), pour afficher le niveau final.
    private func gainDecibels(for lane: Lane) -> Double {
        document.gainDecibels(microphone: lane == .microphone)
    }

    // MARK: - Contenu défilant

    private func content(width: CGFloat, leading: CGFloat, timelineWidth: CGFloat, scale: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: Self.rowSpacing) {
                    ruler(width: timelineWidth, scale: scale)
                    thumbnailStrip(width: timelineWidth, scale: scale)
                    ForEach(lanes, id: \.self) { lane in
                        waveform(lane, width: timelineWidth, scale: scale)
                    }
                }

                segments(scale: scale)
                    .offset(y: Self.rulerHeight + Self.rowSpacing)

                playhead(x: document.currentTime * scale)
            }
            .offset(x: leading)
        }
        .frame(width: width, height: contentHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if document.isPlaying { document.togglePlay() }
                    let time = min(max((value.location.x - leading) / scale, 0), document.duration)
                    document.seek(to: time)
                    document.selectedSegment = document.segmentIndex(at: time)
                }
        )
    }

    private func followPlayhead(_ time: Double, leading: CGFloat, scale: Double) {
        guard trimScale == nil, scroller.visibleWidth > 0 else { return }
        let x = leading + time * scale
        if x < scroller.visibleOffset || x > scroller.visibleOffset + scroller.visibleWidth - 24 {
            scroller.position.scrollTo(x: max(0, x - scroller.visibleWidth * 0.1))
        }
    }

    /// Au zoom (ou quand la marge de gauche change), le point sous les doigts (pincement) ou à défaut
    /// la tête de lecture garde sa position à l'écran.
    private func keepInPlace(from old: Layout, to new: Layout) {
        if let anchor = scroller.zoomAnchor {
            scroller.zoomAnchor = nil
            scroller.position.scrollTo(x: max(0, new.leadingMargin + anchor.time * new.scale - anchor.screenX))
            return
        }
        let time = document.currentTime
        let screenX = old.leadingMargin + time * old.scale - scroller.visibleOffset
        scroller.position.scrollTo(x: max(0, new.leadingMargin + time * new.scale - screenX))
    }

    // MARK: - Règle

    private func ruler(width: CGFloat, scale: Double) -> some View {
        let duration = document.duration
        let interval = Self.tickInterval(scale: scale)
        let color = Theme.textMuted
        return Canvas { context, size in
            var time = 0.0
            while time <= duration + 0.001 {
                let x = time * scale
                context.fill(Path(CGRect(x: x, y: size.height - 5, width: 1, height: 5)), with: .color(color))
                context.draw(
                    Text(Self.rulerLabel(time, interval: interval))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(color),
                    at: CGPoint(x: x + 3, y: 1),
                    anchor: .topLeading
                )
                time += interval
            }
        }
        .frame(width: width, height: Self.rulerHeight)
    }

    private static func tickInterval(scale: Double) -> Double {
        let candidates = [0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return candidates.first { $0 * scale >= 70 } ?? 600
    }

    private static func rulerLabel(_ time: Double, interval: Double) -> String {
        let seconds = Int(time)
        let base = String(format: "%d:%02d", seconds / 60, seconds % 60)
        return interval < 1 ? base + String(format: ".%d", Int((time * 10).rounded()) % 10) : base
    }

    // MARK: - Vignettes

    /// Tuiles de taille fixe tirées du cache de la source : nettes à tous les niveaux de zoom.
    private func thumbnailStrip(width: CGFloat, scale: Double) -> some View {
        let segments = document.state.segments
        let starts = document.segmentStarts
        let thumbnails = document.sourceThumbnails
        let interval = document.sourceThumbnailInterval
        let tileWidth = Self.thumbnailHeight * document.videoAspectRatio

        return Canvas { context, size in
            for (index, segment) in segments.enumerated() {
                let rect = CGRect(x: starts[index] * scale, y: 0, width: segment.range.duration.seconds * scale, height: size.height)
                Self.drawThumbnails(
                    thumbnails, interval: interval, in: &context, rect: rect,
                    source: segment.range.start.seconds, scale: scale, tileWidth: tileWidth
                )
            }
        }
        .frame(width: width, height: Self.thumbnailHeight)
        .background(Theme.backgroundSecondary)
        .overlay(Color.black.opacity(0.2))
    }

    private static func drawThumbnails(
        _ thumbnails: [CGImage],
        interval: Double,
        in context: inout GraphicsContext,
        rect: CGRect,
        source: Double,
        scale: Double,
        tileWidth: CGFloat
    ) {
        var clipped = context
        clipped.clip(to: Path(rect))
        var x: CGFloat = 0
        while x < rect.width {
            let time = source + (x + tileWidth / 2) / scale
            if let image = EditorDocument.thumbnail(in: thumbnails, interval: interval, at: time) {
                clipped.draw(
                    Image(decorative: image, scale: 1),
                    in: CGRect(x: rect.minX + x, y: rect.minY, width: tileWidth, height: rect.height)
                )
            }
            x += tileWidth
        }
    }

    // MARK: - Niveau sonore

    private func envelope(for lane: Lane) -> AudioEnvelope? {
        lane == .systemAudio ? document.systemAudioEnvelope : document.microphoneEnvelope
    }

    private func isEnabled(_ lane: Lane) -> Bool {
        lane == .systemAudio ? document.state.systemAudio : document.state.microphone
    }

    private func waveform(_ lane: Lane, width: CGFloat, scale: Double) -> some View {
        let envelope = envelope(for: lane)
        let enabled = isEnabled(lane)
        let segments = document.state.segments
        let starts = document.segmentStarts
        let color = enabled ? Theme.accent : Theme.textMuted
        let offset = gainDecibels(for: lane)

        return Canvas { context, size in
            guard let envelope else { return }
            for (index, segment) in segments.enumerated() {
                let rect = CGRect(
                    x: starts[index] * scale,
                    y: 0,
                    width: segment.range.duration.seconds * scale,
                    height: size.height
                )
                Self.drawWaveform(
                    envelope, in: &context, rect: rect, source: segment.range.start.seconds,
                    scale: scale, gainDecibels: offset, color: color
                )
            }
        }
        .frame(width: width, height: Self.laneHeight)
        .background(Theme.backgroundSecondary)
        // Piste coupée : toute la ligne est grisée.
        .opacity(enabled ? 1 : 0.35)
    }

    private static func drawWaveform(
        _ envelope: AudioEnvelope,
        in context: inout GraphicsContext,
        rect: CGRect,
        source: Double,
        scale: Double,
        gainDecibels: Double,
        color: Color
    ) {
        let step = 2.0
        let maxHeight = rect.height - 4
        var bars = Path()
        var x = 0.0
        while x < rect.width {
            let peak = envelope.peak(from: source + x / scale, to: source + (x + step) / scale)
            // Niveau final (après gain), affiché de -40 dBFS (vide) à 0 dBFS (pleine hauteur).
            let level = max(0, 1 + (Double(peak) + gainDecibels) / 40)
            if level > 0.02 {
                let height = CGFloat(min(1, level)) * maxHeight
                bars.addRect(CGRect(x: rect.minX + x, y: rect.midY - height / 2, width: step - 0.5, height: height))
            }
            x += step
        }
        context.fill(Path(CGRect(x: rect.minX, y: rect.midY - 0.5, width: rect.width, height: 1)), with: .color(color.opacity(0.35)))
        context.fill(bars, with: .color(color))
    }

    // MARK: - Segments

    private func segments(scale: Double) -> some View {
        let starts = document.segmentStarts
        return ForEach(Array(document.state.segments.enumerated()), id: \.offset) { index, segment in
            segmentView(index: index, segment: segment, scale: scale)
                .offset(x: starts[index] * scale)
                // Le clip rogné passe devant ses voisins, pour que son aperçu les recouvre.
                .zIndex(document.pendingTrim?.index == index ? 1 : 0)
        }
    }

    /// Un segment garde sa place pendant un rognage. Raccourcir : la partie retirée est assombrie.
    /// Rallonger : toute la source disponible jusqu'à la limite apparaît en gris, et la portion sélectionnée
    /// passe en couleur. Les autres clips sont assombris.
    private func segmentView(index: Int, segment: Segment, scale: Double) -> some View {
        let height = tracksHeight
        let width = max(segment.range.duration.seconds * scale, 2)
        let isSelected = document.selectedSegment == index
        let pending = document.pendingTrim?.index == index ? document.pendingTrim : nil
        let isOtherDuringTrim = document.pendingTrim != nil && pending == nil
        let origin = segment.range.start.seconds
        let keptStart = pending.map { ($0.range.start.seconds - origin) * scale } ?? 0
        let keptEnd = pending.map { ($0.range.end.seconds - origin) * scale } ?? width
        let limitStart = (segment.limit.start.seconds - origin) * scale
        let limitEnd = (segment.limit.end.seconds - origin) * scale
        let borderColor = isSelected ? Theme.accent : Color.white.opacity(0.7)

        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Theme.accent.opacity(0.15) : Color.clear)
                .frame(width: width, height: height)

            if isOtherDuringTrim {
                Rectangle().fill(Color.black.opacity(0.5))
                    .frame(width: width, height: height)
            }

            if let pending {
                // Source disponible, en gris.
                if pending.edge == .start, limitStart < 0 {
                    sourcePreview(from: segment.limit.start.seconds, width: -limitStart, scale: scale, active: false)
                        .offset(x: limitStart)
                }
                if pending.edge == .end, limitEnd > width {
                    sourcePreview(from: segment.range.end.seconds, width: limitEnd - width, scale: scale, active: false)
                        .offset(x: width)
                }
                limitMarker(x: pending.edge == .start ? limitStart : limitEnd)
            }

            if keptStart > 0 {
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: keptStart, height: height)
            }
            if keptEnd < width {
                Rectangle().fill(Color.black.opacity(0.6))
                    .frame(width: width - keptEnd, height: height)
                    .offset(x: keptEnd)
            }
            // Portion ajoutée, en couleur.
            if keptStart < 0 {
                sourcePreview(from: origin + keptStart / scale, width: -keptStart, scale: scale, active: true)
                    .offset(x: keptStart)
            }
            if keptEnd > width {
                sourcePreview(from: segment.range.end.seconds, width: keptEnd - width, scale: scale, active: true)
                    .offset(x: width)
            }

            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
                .frame(width: width, height: height)

            trimHandle(index: index, edge: .start, scale: scale, isSelected: isSelected)
                .offset(x: keptStart)
            trimHandle(index: index, edge: .end, scale: scale, isSelected: isSelected)
                .offset(x: keptEnd - Self.handleWidth)
        }
        .frame(width: width, height: height, alignment: .topLeading)
    }

    /// Aperçu opaque de la source (vignettes + son) : en gris pour la partie disponible,
    /// en couleur pour la portion ajoutée.
    private func sourcePreview(from source: Double, width: CGFloat, scale: Double, active: Bool) -> some View {
        let envelopes = lanes.map { envelope(for: $0) }
        let enabled = lanes.map { isEnabled($0) }
        let offsets = lanes.map { gainDecibels(for: $0) }
        let thumbnails = document.sourceThumbnails
        let interval = document.sourceThumbnailInterval
        let tileWidth = Self.thumbnailHeight * document.videoAspectRatio

        return Canvas { context, size in
            Self.drawThumbnails(
                thumbnails, interval: interval, in: &context,
                rect: CGRect(x: 0, y: 0, width: size.width, height: Self.thumbnailHeight),
                source: source, scale: scale, tileWidth: tileWidth
            )
            for (lane, envelope) in envelopes.enumerated() {
                guard let envelope else { continue }
                let y = Self.thumbnailHeight + Self.rowSpacing + CGFloat(lane) * (Self.laneHeight + Self.rowSpacing)
                Self.drawWaveform(
                    envelope,
                    in: &context,
                    rect: CGRect(x: 0, y: y, width: size.width, height: Self.laneHeight),
                    source: source,
                    scale: scale,
                    gainDecibels: offsets[lane],
                    color: enabled[lane] ? Theme.accent : Theme.textMuted
                )
            }
        }
        .frame(width: width, height: tracksHeight)
        .saturation(active ? 1 : 0)
        .opacity(active ? 1 : 0.55)
        .background(Theme.backgroundPrimary)
        .overlay {
            if active {
                Rectangle().strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }

    /// Trait en pointillés à la limite jusqu'où le clip peut être rallongé.
    private func limitMarker(x: CGFloat) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: tracksHeight))
        }
        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .allowsHitTesting(false)
    }

    private func trimHandle(index: Int, edge: SegmentEdge, scale: Double, isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(isSelected ? Theme.accent : Color.white.opacity(0.85))
            .frame(width: Self.handleWidth, height: tracksHeight)
            .overlay(
                Capsule()
                    .fill(isSelected ? Color.white : Color.black.opacity(0.5))
                    .frame(width: 2, height: 16)
            )
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if trimDrag == nil {
                            trimScale = scale
                            document.selectedSegment = index
                            trimDrag = TrimDrag(
                                index: index,
                                edge: edge,
                                startOffset: scroller.visibleOffset,
                                translation: 0,
                                locationX: value.location.x
                            )
                        }
                        trimDrag?.translation = value.translation.width
                        trimDrag?.locationX = value.location.x
                        updateTrimPreview()
                        startAutoScrollIfNeeded()
                    }
                    .onEnded { _ in
                        autoScrollTask?.cancel()
                        autoScrollTask = nil
                        document.commitTrim()
                        trimDrag = nil
                        trimScale = nil
                    }
            )
    }

    /// La poignée suit la souris en tenant compte du défilement survenu depuis le début du glisser.
    private func updateTrimPreview() {
        guard let trimDrag, let trimScale else { return }
        let contentDelta = trimDrag.translation + (scroller.visibleOffset - trimDrag.startOffset)
        document.previewTrim(segment: trimDrag.index, edge: trimDrag.edge, by: contentDelta / trimScale)
    }

    /// Vitesse de défilement (points par image) quand la souris approche ou dépasse un bord de la timeline.
    private func autoScrollSpeed() -> CGFloat {
        guard let trimDrag, scroller.viewportFrame.width > 0 else { return 0 }
        let x = trimDrag.locationX
        let zone = Self.autoScrollZone
        if x < scroller.viewportFrame.minX + zone {
            return -min(30, (scroller.viewportFrame.minX + zone - x) / 3)
        }
        if x > scroller.viewportFrame.maxX - zone {
            return min(30, (x - (scroller.viewportFrame.maxX - zone)) / 3)
        }
        return 0
    }

    private func startAutoScrollIfNeeded() {
        guard autoScrollTask == nil, autoScrollSpeed() != 0 else { return }
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                let speed = autoScrollSpeed()
                let maxOffset = max(0, scroller.contentWidth - scroller.visibleWidth)
                let offset = min(max(scroller.visibleOffset + speed, 0), maxOffset)
                if speed == 0 || offset == scroller.visibleOffset { break }
                scroller.visibleOffset = offset
                scroller.position.scrollTo(x: offset)
                updateTrimPreview()
                try? await Task.sleep(for: .milliseconds(16))
            }
            autoScrollTask = nil
        }
    }

    // MARK: - Tête de lecture

    private func playhead(x: Double) -> some View {
        VStack(spacing: 0) {
            Triangle()
                .fill(Theme.accent)
                .frame(width: 10, height: 6)
            Rectangle()
                .fill(Theme.accent)
                .frame(width: 2)
        }
        .frame(width: 10, height: contentHeight)
        .offset(x: x - 5)
        .allowsHitTesting(false)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
