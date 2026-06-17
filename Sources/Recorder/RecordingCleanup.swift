import Foundation

struct RecordingCleanupResult: Equatable {
    var deletedCount: Int
    var failedCount: Int

    static let empty = RecordingCleanupResult(deletedCount: 0, failedCount: 0)
}

enum RecordingCleanup {
    static func deleteExpiredUploadedRecordings(
        policy: RecordingRetentionPolicy,
        now: Date = Date(),
        rootURL: URL? = nil
    ) -> RecordingCleanupResult {
        let root = rootURL ?? RecordingsLibrary.recordingsRoot()
        guard let days = policy.retentionDays,
              let root,
              let folders = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
              ) else {
            return .empty
        }

        let cutoff = now.addingTimeInterval(-TimeInterval(days) * 24 * 60 * 60)
        var result = RecordingCleanupResult.empty

        for folder in folders {
            guard isDirectory(folder),
                  shouldDelete(folderURL: folder, cutoff: cutoff) else {
                continue
            }

            do {
                try FileManager.default.removeItem(at: folder)
                result.deletedCount += 1
            } catch {
                UploadStatusStore.appendLog(folderURL: folder, "Local cleanup failed: \(error.localizedDescription)")
                result.failedCount += 1
            }
        }

        return result
    }

    private static func shouldDelete(folderURL: URL, cutoff: Date) -> Bool {
        guard let metadata = UploadStatusStore.readMetadata(folderURL: folderURL),
              metadata.uploadStatus == "uploaded",
              metadata.minuteURL?.isEmpty == false else {
            return false
        }

        let referenceDate = metadata.endedAt ?? metadata.updatedAt
        return referenceDate <= cutoff
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
