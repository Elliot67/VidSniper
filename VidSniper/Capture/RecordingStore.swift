import Foundation

/// Fichiers temporaires des enregistrements et des exports, purgés après 24 h.
enum RecordingStore {
    static var directory: URL {
        cacheDirectory("Recordings")
    }

    static var exportsDirectory: URL {
        cacheDirectory("Exports")
    }

    private static func cacheDirectory(_ name: String) -> URL {
        let directory = URL.cachesDirectory.appending(path: "VidSniper/\(name)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = String(localized: "yyyy-MM-dd 'at' HH.mm.ss", comment: "Date format of the recording file name")
        return directory.appending(path: "VidSniper \(formatter.string(from: .now)).mov")
    }

    static func purgeOldRecordings(olderThan age: TimeInterval = 24 * 3600) {
        let fileManager = FileManager.default
        let limit = Date.now.addingTimeInterval(-age)
        for folder in [directory, exportsDirectory] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey]
            ) else { continue }

            for file in files {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                if let modified, modified < limit {
                    try? fileManager.removeItem(at: file)
                }
            }
        }
    }
}
