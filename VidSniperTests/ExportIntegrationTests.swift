import AVFoundation
import CoreGraphics
import Testing
@testable import VidSniper

/// Export réel en MP4 (encodeur vidéo de macOS) : dimensions, durée, images par seconde, son, couleurs, poids.
/// Lancés par ./scripts/test.sh (pas dans le bac à sable de Claude Code, qui bloque l'encodeur).
@Suite(.enabled(if: Fixtures.runsIntegration, "tests d'intégration : ./scripts/test.sh"), .timeLimit(.minutes(1)))
struct ExportIntegrationTests {
    /// Toute la vidéo en une composition, comme l'éditeur sans retouche.
    private func composition(of url: URL) async throws -> AVComposition {
        let asset = AVURLAsset(url: url)
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        try await composition.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: asset, at: .zero)
        if let source = try await asset.loadTracks(withMediaType: .video).first,
           let track = composition.tracks(withMediaType: .video).first {
            track.preferredTransform = try await source.load(.preferredTransform)
        }
        return composition
    }

    private func export(
        _ url: URL,
        pixelsPerPoint: Double = 2,
        resolution: ExportResolution = .screen,
        quality: ExportQuality = .balanced
    ) async throws -> (url: URL, plan: ExportPlan) {
        let composition = try await composition(of: url)
        let videoTrack = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let size = try await videoTrack.load(.naturalSize)
        let hasAudio = !(try await composition.loadTracks(withMediaType: .audio)).isEmpty
        let plan = ExportPlan(
            sourceSize: size,
            pixelsPerPoint: pixelsPerPoint,
            duration: try await composition.load(.duration).seconds,
            hasAudio: hasAudio,
            resolution: resolution,
            quality: quality
        )
        let output = FileManager.default.temporaryDirectory.appending(path: "VidSniperTests-\(UUID().uuidString).mp4")
        try await VideoExporter.export(composition, plan: plan, volumes: [], clicks: nil, annotations: nil, to: output) { _ in }
        return (output, plan)
    }

    private func fileSize(_ url: URL) throws -> Int {
        try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    }

    @Test func exportsARecordingAtScreenSize() async throws {
        let (url, plan) = try await export(try Fixtures.recording)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)

        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(Int(size.width) == plan.width && Int(size.height) == plan.height)
        #expect(plan.width == 640 && plan.height == 360)
        #expect(isClose(try await asset.load(.duration).seconds, 3, tolerance: 0.1))
        #expect(isClose(Double(try await video.load(.nominalFrameRate)), 30, tolerance: 1))

        // Les deux pistes audio de l'enregistrement sont mixées en une seule.
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func exportIsTaggedLikeTheRecording() async throws {
        let (url, _) = try await export(try Fixtures.recording)
        defer { try? FileManager.default.removeItem(at: url) }
        let video = try #require(try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first)
        let format = try #require(try await video.load(.formatDescriptions).first)
        let extensions = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        #expect(extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
            == kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String)
        #expect(extensions[kCMFormatDescriptionExtension_TransferFunction as String] as? String
            == kCMFormatDescriptionTransferFunction_sRGB as String)
        #expect(extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
            == kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
    }

    /// Les couleurs du MP4 restent celles de la source : on compare la même image, réduite, couleur par couleur.
    @Test func colorsMatchTheSource() async throws {
        let source = try Fixtures.recording
        let (url, _) = try await export(source, quality: .maximum)
        defer { try? FileManager.default.removeItem(at: url) }

        let original = try await pixels(of: source, at: 1.5)
        let exported = try await pixels(of: url, at: 1.5)
        let difference = zip(original, exported).map { abs(Int($0) - Int($1)) }
        let average = Double(difference.reduce(0, +)) / Double(difference.count)
        #expect(average < 4, "écart moyen par canal : \(average)")
    }

    @Test func lighterLevelsGiveSmallerFiles() async throws {
        var sizes: [Int] = []
        for quality in [ExportQuality.maximum, .balanced, .veryLight] {
            let (url, _) = try await export(try Fixtures.recording, resolution: .full, quality: quality)
            sizes.append(try fileSize(url))
            try? FileManager.default.removeItem(at: url)
        }
        #expect(sizes == sizes.sorted(by: >), "poids : \(sizes)")
    }

    @Test func exportsAnImportedVideo() async throws {
        let (url, plan) = try await export(try Fixtures.imported, pixelsPerPoint: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(plan.width == 640 && Int(size.width) == 640)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func exportsTheRealReferenceRecording() async throws {
        let source = try #require(Fixtures.reference, "VidSniperTests/Fixtures/reference.mov absent")
        let (url, plan) = try await export(source)
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let sourceDuration = try await AVURLAsset(url: source).load(.duration).seconds
        #expect(isClose(try await asset.load(.duration).seconds, sourceDuration, tolerance: 0.1))
        let video = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await video.load(.naturalSize)
        #expect(Int(size.width) == plan.width && Int(size.height) == plan.height)
    }

    /// Image réduite à 64 × 36, en sRGB (gestion des couleurs du système, selon les étiquettes du fichier).
    private func pixels(of url: URL, at seconds: Double) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
        let width = 64, height = 36
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
            context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}
