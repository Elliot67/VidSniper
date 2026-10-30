import Foundation

/// Fichiers temporaires des enregistrements, purgés après 24 h.
enum RecordingStore {
    static var directory: URL {
        let directory = URL.cachesDirectory.appending(path: "VidSniper/Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        return directory.appending(path: "VidSniper \(formatter.string(from: .now)).mov")
    }

    static func purgeOldRecordings(olderThan age: TimeInterval = 24 * 3600) {
        let fileManager = FileManager.default
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let limit = Date.now.addingTimeInterval(-age)
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < limit {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}
