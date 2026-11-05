import Foundation
import Testing
@testable import VidSniper

/// Montage sur la vidéo de test de 3 s : couper, supprimer, rallonger, annuler, pistes audio, clics.
@MainActor
@Suite(.timeLimit(.minutes(1)))
struct EditorTests {
    private func makeDocument(clicks: [ClickMark] = []) async throws -> EditorDocument {
        let recording = RecordingResult(
            url: try Fixtures.recording,
            hasSystemAudio: true,
            hasMicrophone: true,
            pixelsPerPoint: 2,
            clicks: clicks
        )
        let document = EditorDocument(recording: recording)
        await document.load()
        try #require(document.isReady, "chargement : \(document.loadError ?? "?")")
        return document
    }

    @Test func loadsTheWholeVideoAsOneSegment() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        #expect(isClose(document.duration, 3))
        #expect(document.state.segments.count == 1)
        #expect(document.hasSystemAudioTrack && document.hasMicrophoneTrack)
        #expect(!document.canUndo)
    }

    @Test func cutSplitsWithoutChangingTheDuration() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        document.seek(to: 1)
        document.cutAtPlayhead()
        #expect(document.state.segments.count == 2)
        #expect(isClose(document.duration, 3))
        #expect(isClose(document.state.segments[0].range.duration.seconds, 1))
        #expect(document.canUndo)
    }

    @Test func cutTooCloseToAnEdgeDoesNothing() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        document.seek(to: 0.05)
        document.cutAtPlayhead()
        #expect(document.state.segments.count == 1)
        #expect(!document.canUndo)
    }

    @Test func deleteThenUndoAndRedo() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        document.seek(to: 1)
        document.cutAtPlayhead()
        document.selectedSegment = 1
        document.deleteSelectedSegment()
        #expect(isClose(document.duration, 1))

        document.undo()
        #expect(isClose(document.duration, 3))
        #expect(document.state.segments.count == 2)

        document.redo()
        #expect(isClose(document.duration, 1))
        #expect(!document.canRedo)
    }

    @Test func theLastSegmentCannotBeDeleted() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        document.selectedSegment = 0
        document.deleteSelectedSegment()
        #expect(document.state.segments.count == 1)
    }

    @Test func extendingASegmentRecoversADeletedNeighbour() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        document.seek(to: 1.5)
        document.cutAtPlayhead()
        document.selectedSegment = 0
        document.deleteSelectedSegment()
        #expect(isClose(document.duration, 1.5))

        // Rallonger le début bien au-delà : bloqué au début de la source, la partie supprimée revient.
        document.previewTrim(segment: 0, edge: .start, by: -10)
        document.commitTrim()
        #expect(isClose(document.duration, 3))
        #expect(isClose(document.state.segments[0].range.start.seconds, 0))
    }

    @Test func trimStopsAtTheNextSegment() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        document.seek(to: 1)
        document.cutAtPlayhead()
        document.previewTrim(segment: 0, edge: .end, by: 5)
        document.commitTrim()
        // Les segments ne se chevauchent jamais : la fin du premier s'arrête au début du second.
        #expect(isClose(document.state.segments[0].range.end.seconds, 1))
    }

    @Test func audioTracksCanBeTurnedOffAndBackWithUndo() async throws {
        let document = try await makeDocument()
        defer { document.close() }
        document.setMicrophone(false)
        #expect(!document.state.microphone)
        #expect(document.state.systemAudio)
        document.undo()
        #expect(document.state.microphone)
    }

    @Test func clicksFollowTheEdit() async throws {
        let document = try await makeDocument(clicks: [
            ClickMark(time: 0.5, x: 0.1, y: 0.1),
            ClickMark(time: 2, x: 0.5, y: 0.5),
        ])
        defer { document.close() }
        document.seek(to: 1)
        document.cutAtPlayhead()
        document.selectedSegment = 0
        document.deleteSelectedSegment()
        // Le clic du segment supprimé disparaît, l'autre est recalé sur le montage (2 s - 1 s supprimée).
        let clicks = document.compositionClicks
        #expect(clicks.count == 1)
        #expect(isClose(clicks.first?.time ?? -1, 1))
    }
}

/// Zoom de l'aperçu de l'onglet Export (paliers ronds, jamais sous l'ajustement).
@MainActor
struct PreviewZoomTests {
    private func makeDocument() throws -> EditorDocument {
        let document = EditorDocument(recording: RecordingResult(
            url: try Fixtures.recording, hasSystemAudio: true, hasMicrophone: true, pixelsPerPoint: 2
        ))
        document.previewFitZoom = 0.63
        return document
    }

    @Test func zoomingInGoesToTheNextRoundStep() throws {
        let document = try makeDocument()
        document.stepPreviewZoom(zoomIn: true)
        #expect(document.previewZoom == 0.75)
        document.stepPreviewZoom(zoomIn: true)
        #expect(document.previewZoom == 1)
        document.stepPreviewZoom(zoomIn: true)
        #expect(document.previewZoom == 1.25)
    }

    @Test func zoomingOutStopsAtFit() throws {
        let document = try makeDocument()
        document.setPreviewZoom(0.75)
        document.stepPreviewZoom(zoomIn: false)
        // 50 % serait sous l'ajustement (63 %) : on revient à "Ajuster".
        #expect(document.previewZoom == nil)
        #expect(document.displayedPreviewZoom == 0.63)
    }

    @Test func zoomIsCappedAtTheMaximum() throws {
        let document = try makeDocument()
        document.setPreviewZoom(50)
        #expect(document.previewZoom == EditorDocument.previewZoomRange.upperBound)
    }
}
