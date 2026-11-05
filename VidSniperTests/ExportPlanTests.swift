import CoreGraphics
import Testing
@testable import VidSniper

/// Dimensions, débit et poids estimé d'un export.
struct ExportPlanTests {
    private func plan(
        _ width: Double, _ height: Double,
        pixelsPerPoint: Double = 2,
        resolution: ExportResolution = .full,
        quality: ExportQuality = .balanced,
        duration: Double = 10,
        hasAudio: Bool = true
    ) -> ExportPlan {
        ExportPlan(
            sourceSize: CGSize(width: width, height: height),
            pixelsPerPoint: pixelsPerPoint,
            duration: duration,
            hasAudio: hasAudio,
            resolution: resolution,
            quality: quality
        )
    }

    @Test func retinaKeepsAllCapturedPixels() {
        let plan = plan(2560, 1600, resolution: .full)
        #expect(plan.width == 2560 && plan.height == 1600)
    }

    @Test func screenHalvesARetinaRecording() {
        let plan = plan(2560, 1600, resolution: .screen)
        #expect(plan.width == 1280 && plan.height == 800)
    }

    @Test func screenKeepsAnImportedVideoAsIs() {
        let plan = plan(640, 360, pixelsPerPoint: 1, resolution: .screen)
        #expect(plan.width == 640 && plan.height == 360)
    }

    @Test func dimensionsAreEven() {
        let plan = plan(1001, 601, pixelsPerPoint: 1)
        #expect(plan.width == 1000 && plan.height == 600)
    }

    @Test func fiveKIsReducedToTheHardwareEncoderLimit() {
        let plan = plan(5120, 2880, resolution: .full)
        #expect(plan.width == 4096 && plan.height == 2304)
    }

    @Test func eachLevelIsLighterThanThePreviousOne() {
        let bitrates = ExportQuality.allCases.map { plan(1920, 1080, pixelsPerPoint: 1, quality: $0).videoBitrate }
        #expect(bitrates == bitrates.sorted(by: >))
        #expect(Set(bitrates).count == bitrates.count)
    }

    @Test func levelsStayDistinctOnAMediumZone() {
        // 1000 × 600 : avec l'ancien plancher (500 kb/s), Équilibrée, Légère et Très légère donnaient le même fichier.
        let bitrates = ExportQuality.allCases.map { plan(1000, 600, pixelsPerPoint: 1, quality: $0).videoBitrate }
        #expect(Set(bitrates).count == bitrates.count)
    }

    @Test func bitrateNeverGoesBelowTheFloor() {
        let plan = plan(100, 60, pixelsPerPoint: 1, quality: .veryLight)
        #expect(plan.videoBitrate == 200_000)
    }

    @Test func estimatedSizeFollowsBitrateAndDuration() {
        let withAudio = plan(1920, 1080, pixelsPerPoint: 1, duration: 10, hasAudio: true)
        let withoutAudio = plan(1920, 1080, pixelsPerPoint: 1, duration: 10, hasAudio: false)
        let expected = Double(withAudio.videoBitrate + ExportPlan.audioBitrate) * 10 / 8 * 1.01
        #expect(isClose(Double(withAudio.estimatedBytes), expected, tolerance: 1))
        #expect(withoutAudio.estimatedBytes < withAudio.estimatedBytes)
        #expect(plan(1920, 1080, pixelsPerPoint: 1, duration: 20).estimatedBytes > withAudio.estimatedBytes)
    }
}

/// Petits utilitaires d'affichage.
@MainActor
struct FormattingTests {
    @Test func playbackTimeShowsMinutesSecondsAndTenths() {
        #expect(EditorView.format(0) == "0:00.0")
        #expect(EditorView.format(65.34) == "1:05.3")
        #expect(EditorView.format(-3) == "0:00.0")
    }
}
