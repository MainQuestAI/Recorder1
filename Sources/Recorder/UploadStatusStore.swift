import Foundation

struct RecordingMetadata: Codable, Equatable {
    var meetingTitle: String?
    var attendees: [String]
    var startedAt: Date?
    var endedAt: Date?
    var localPath: String
    var desktopPath: String
    var micPath: String
    var audioPath: String
    var fileToken: String?
    var minuteURL: String?
    var minuteToken: String?
    var uploadStatus: String
    var lastError: String?
    var audioQuality: AudioQualityReport?
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case meetingTitle = "meeting_title"
        case attendees
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case localPath = "local_path"
        case desktopPath = "desktop_path"
        case micPath = "mic_path"
        case audioPath = "audio_path"
        case fileToken = "file_token"
        case minuteURL = "minute_url"
        case minuteToken = "minute_token"
        case uploadStatus = "upload_status"
        case lastError = "last_error"
        case audioQuality = "audio_quality"
        case updatedAt = "updated_at"
    }
}

enum UploadStatusStore {
    private static let metadataFile = "metadata.json"
    private static let logFile = "upload.log"

    static func writeInitial(session: RecordingSession, meeting: Meeting?) {
        let metadata = RecordingMetadata(
            meetingTitle: meeting?.title ?? session.meetingTitle,
            attendees: meeting?.attendees ?? [],
            startedAt: session.startedAt,
            endedAt: nil,
            localPath: session.folderURL.path,
            desktopPath: session.desktopURL.path,
            micPath: session.micURL.path,
            audioPath: session.outputURL.path,
            fileToken: nil,
            minuteURL: nil,
            minuteToken: nil,
            uploadStatus: "recording",
            lastError: nil,
            audioQuality: nil,
            updatedAt: Date()
        )
        write(metadata, folderURL: session.folderURL)
        appendLog(folderURL: session.folderURL, "Recording started.")
    }

    static func markSaved(job: FeishuUploadJob) {
        update(folderURL: job.folderURL) { metadata in
            metadata.meetingTitle = job.meetingTitle
            metadata.attendees = job.attendees
            metadata.startedAt = job.startedAt
            metadata.endedAt = job.endedAt
            metadata.audioPath = job.audioURL.path
            metadata.uploadStatus = "saved"
            metadata.lastError = nil
        }
        appendLog(folderURL: job.folderURL, "audio.m4a saved.")
    }

    static func markAudioQuality(folderURL: URL, report: AudioQualityReport) {
        update(folderURL: folderURL) { metadata in
            metadata.audioQuality = report
        }
        appendLog(
            folderURL: folderURL,
            String(
                format: "Audio quality: duration=%.3fs channels=%d left_desktop_rms=%.1fdB right_mic_rms=%.1fdB",
                report.durationSeconds,
                report.channelCount,
                report.leftDesktopRMSDB,
                report.rightMicRMSDB
            )
        )
        for warning in report.warnings {
            appendLog(folderURL: folderURL, "Audio quality warning: \(warning)")
        }
    }

    static func markCaptureFailed(session: RecordingSession, meeting: Meeting?, error: Error) {
        let message = describe(error)
        update(folderURL: session.folderURL) { metadata in
            metadata.meetingTitle = meeting?.title ?? session.meetingTitle
            metadata.attendees = meeting?.attendees ?? []
            metadata.startedAt = session.startedAt
            metadata.endedAt = Date()
            metadata.uploadStatus = "capture_failed"
            metadata.lastError = message
        }
        appendLog(folderURL: session.folderURL, "Capture failed: \(message)")
    }

    static func markUploading(job: FeishuUploadJob) {
        update(folderURL: job.folderURL) { metadata in
            metadata.uploadStatus = "uploading"
            metadata.lastError = nil
        }
        appendLog(folderURL: job.folderURL, "Feishu upload started.")
    }

    static func markFileUploaded(folderURL: URL, fileToken: String) {
        update(folderURL: folderURL) { metadata in
            metadata.fileToken = fileToken
            metadata.uploadStatus = "file_uploaded"
            metadata.lastError = nil
        }
        appendLog(folderURL: folderURL, "Drive upload succeeded. file_token=\(fileToken)")
    }

    static func markMinuteCreated(folderURL: URL, minuteURL: URL, minuteToken: String) {
        update(folderURL: folderURL) { metadata in
            metadata.minuteURL = minuteURL.absoluteString
            metadata.minuteToken = minuteToken
            metadata.uploadStatus = "minute_created"
            metadata.lastError = nil
        }
        appendLog(folderURL: folderURL, "Feishu Minutes created. minute_url=\(minuteURL.absoluteString)")
    }

    static func markUploaded(result: FeishuUploadResult, folderURL: URL) {
        update(folderURL: folderURL) { metadata in
            metadata.fileToken = result.fileToken
            metadata.minuteURL = result.minuteURL.absoluteString
            metadata.minuteToken = result.minuteToken
            metadata.uploadStatus = "uploaded"
            metadata.lastError = result.notesFetchError
        }
        if let error = result.notesFetchError {
            appendLog(folderURL: folderURL, "Upload completed; notes fetch issue: \(error)")
        } else {
            appendLog(folderURL: folderURL, "Upload completed.")
        }
    }

    static func markFailed(job: FeishuUploadJob, error: Error) {
        let message = describe(error)
        update(folderURL: job.folderURL) { metadata in
            metadata.meetingTitle = job.meetingTitle
            metadata.attendees = job.attendees
            metadata.startedAt = job.startedAt
            metadata.endedAt = job.endedAt
            metadata.audioPath = job.audioURL.path
            metadata.uploadStatus = "failed"
            metadata.lastError = message
        }
        appendLog(folderURL: job.folderURL, "Upload failed: \(message)")
    }

    static func readMetadata(folderURL: URL) -> RecordingMetadata? {
        let url = folderURL.appendingPathComponent(metadataFile)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RecordingMetadata.self, from: data)
    }

    static func appendLog(folderURL: URL, _ message: String) {
        let formatter = ISO8601DateFormatter()
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        let url = folderURL.appendingPathComponent(logFile)

        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func update(folderURL: URL, _ mutate: (inout RecordingMetadata) -> Void) {
        var metadata = readMetadata(folderURL: folderURL) ?? fallbackMetadata(folderURL: folderURL)
        mutate(&metadata)
        metadata.updatedAt = Date()
        write(metadata, folderURL: folderURL)
    }

    private static func write(_ metadata: RecordingMetadata, folderURL: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(metadata) else { return }
        try? data.write(to: folderURL.appendingPathComponent(metadataFile), options: .atomic)
    }

    private static func fallbackMetadata(folderURL: URL) -> RecordingMetadata {
        let (date, title) = RecordingsLibrary.parseFolderName(folderURL.lastPathComponent)
        return RecordingMetadata(
            meetingTitle: title,
            attendees: [],
            startedAt: date,
            endedAt: nil,
            localPath: folderURL.path,
            desktopPath: folderURL.appendingPathComponent("desktop.caf").path,
            micPath: folderURL.appendingPathComponent("mic.caf").path,
            audioPath: folderURL.appendingPathComponent("audio.m4a").path,
            fileToken: nil,
            minuteURL: nil,
            minuteToken: nil,
            uploadStatus: "unknown",
            lastError: nil,
            audioQuality: nil,
            updatedAt: Date()
        )
    }

    private static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
