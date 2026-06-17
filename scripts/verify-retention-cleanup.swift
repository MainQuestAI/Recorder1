import Darwin
import Foundation

enum RetentionProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw RetentionProbeError.failed(message) }
}

@main
struct RetentionCleanupProbe {
    static func main() {
        do {
            try run()
            print("PASS local retention cleanup only deletes expired uploaded recordings")
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("recorder1-retention-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredUploaded = try makeRecording(
            root: root,
            name: "2027-01-01_0900-expired-uploaded",
            startedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
            uploaded: true,
            minuteURL: true
        )
        let recentUploaded = try makeRecording(
            root: root,
            name: "2027-01-10_0900-recent-uploaded",
            startedAt: now.addingTimeInterval(-10 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-9 * 24 * 60 * 60),
            uploaded: true,
            minuteURL: true
        )
        let expiredFailed = try makeRecording(
            root: root,
            name: "2027-01-01_1000-expired-failed",
            startedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
            uploaded: false,
            minuteURL: false
        )
        let expiredNoMinuteURL = try makeRecording(
            root: root,
            name: "2027-01-01_1100-expired-no-minute",
            startedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            endedAt: now.addingTimeInterval(-30 * 24 * 60 * 60),
            uploaded: true,
            minuteURL: false
        )

        let keepResult = RecordingCleanup.deleteExpiredUploadedRecordings(
            policy: .keepForever,
            now: now,
            rootURL: root
        )
        try require(keepResult == .empty, "keep policy deleted or failed unexpectedly")
        try require(FileManager.default.fileExists(atPath: expiredUploaded.path), "keep policy removed uploaded folder")

        let cleanupResult = RecordingCleanup.deleteExpiredUploadedRecordings(
            policy: .deleteAfter15Days,
            now: now,
            rootURL: root
        )
        try require(cleanupResult.deletedCount == 1, "expected one deleted folder, got \(cleanupResult.deletedCount)")
        try require(cleanupResult.failedCount == 0, "expected no cleanup failures, got \(cleanupResult.failedCount)")
        try require(!FileManager.default.fileExists(atPath: expiredUploaded.path), "expired uploaded folder still exists")
        try require(FileManager.default.fileExists(atPath: recentUploaded.path), "recent uploaded folder was deleted")
        try require(FileManager.default.fileExists(atPath: expiredFailed.path), "failed upload folder was deleted")
        try require(FileManager.default.fileExists(atPath: expiredNoMinuteURL.path), "folder without minute_url was deleted")
    }

    private static func makeRecording(
        root: URL,
        name: String,
        startedAt: Date,
        endedAt: Date,
        uploaded: Bool,
        minuteURL hasMinuteURL: Bool
    ) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("audio.m4a")
        try Data("retention-probe".utf8).write(to: audioURL, options: .atomic)

        let job = FeishuUploadJob(
            audioURL: audioURL,
            folderURL: folder,
            meetingTitle: name,
            attendees: [],
            startedAt: startedAt,
            endedAt: endedAt
        )
        UploadStatusStore.markSaved(job: job)

        if uploaded {
            if hasMinuteURL {
                UploadStatusStore.markUploaded(
                    result: FeishuUploadResult(
                        fileToken: "file-\(name)",
                        minuteURL: URL(string: "https://example.feishu.cn/minutes/\(name)")!,
                        minuteToken: "minute-\(name)",
                        minutesJSONURL: folder.appendingPathComponent("feishu_minutes.json"),
                        transcriptURL: nil,
                        summaryURL: nil,
                        notesFetchError: nil
                    ),
                    folderURL: folder
                )
            } else {
                UploadStatusStore.markFileUploaded(folderURL: folder, fileToken: "file-\(name)")
            }
        } else {
            UploadStatusStore.markFailed(
                job: job,
                error: RetentionProbeError.failed("synthetic upload failure")
            )
        }

        return folder
    }
}
