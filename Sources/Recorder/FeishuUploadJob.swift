import Foundation

struct FeishuUploadJob: Equatable {
    let audioURL: URL
    let folderURL: URL
    let meetingTitle: String?
    let attendees: [String]
    let startedAt: Date
    let endedAt: Date

    var audioRelativePath: String {
        uploadFileName
    }

    var uploadFileName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd_HHmm"

        let title = meetingTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
            .map(Meeting.sanitize) ?? "Recorder1"

        return "\(formatter.string(from: startedAt))-\(title).m4a"
    }

    func prepareAudioForUpload() throws -> URL {
        let uploadURL = folderURL.appendingPathComponent(uploadFileName)
        if uploadURL.standardizedFileURL == audioURL.standardizedFileURL {
            return audioURL
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: uploadURL.path) {
            try fm.removeItem(at: uploadURL)
        }
        try fm.copyItem(at: audioURL, to: uploadURL)
        return uploadURL
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

struct FeishuUploadResult: Equatable {
    let fileToken: String
    let minuteURL: URL
    let minuteToken: String
    let minutesJSONURL: URL
    let transcriptURL: URL?
    let summaryURL: URL?
    let notesFetchError: String?
}
