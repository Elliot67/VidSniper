import AVFoundation
import UniformTypeIdentifiers

enum ImportError: LocalizedError {
    case unreadable(Error?)
    case noVideo

    var errorDescription: String? {
        switch self {
        case .unreadable(let error):
            "Cette vidéo ne peut pas être lue\(error.map { " : \($0.localizedDescription)" } ?? ".")"
        case .noVideo:
            "Ce fichier ne contient pas d'image vidéo."
        }
    }
}

/// Prépare une vidéo existante pour l'éditeur. Le fichier est lu en place : jamais copié, modifié ni purgé.
enum VideoImporter {
    static let contentTypes: [UTType] = [.movie]

    static func inspect(_ url: URL) async throws -> RecordingResult {
        let asset = AVURLAsset(url: url)
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            guard try await asset.load(.isReadable) else { throw ImportError.unreadable(nil) }
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.unreadable(error)
        }
        guard !videoTracks.isEmpty else { throw ImportError.noVideo }

        // L'éditeur gère deux pistes audio : les suivantes, rares, sont ignorées.
        return RecordingResult(
            url: url,
            hasSystemAudio: audioTracks.count >= 1,
            hasMicrophone: audioTracks.count >= 2,
            pixelsPerPoint: 1,
            isImported: true
        )
    }
}
