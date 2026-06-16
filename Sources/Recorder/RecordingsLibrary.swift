import Foundation

/// One past recording on disk (a folder under ~/Documents/MeetingCapture).
struct RecordingEntry: Identifiable, Equatable {
    /// Folder path — stable identity.
    var id: String { folderURL.path }
    let folderURL: URL
    /// Parsed meeting title (nil for ad-hoc recordings).
    let title: String?
    /// Best timestamp for the recording (parsed from the folder name, else file date).
    let date: Date
    /// audio.m4a, if it exists.
    let audioURL: URL?
    /// transcript.md, if it exists.
    let transcriptURL: URL?
    /// Parsed from metadata.json after a successful Feishu upload.
    let minuteURL: URL?
    /// Parsed upload status from metadata.json.
    let uploadStatus: String?

    var hasTranscript: Bool { transcriptURL != nil }
    var isUploaded: Bool { minuteURL != nil || uploadStatus == "uploaded" }
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "Recording"
    }
}

/// Reads the on-disk recordings library so the panel can show prior recordings
/// (and their upload state) after a restart — the in-memory list doesn't survive
/// relaunches.
enum RecordingsLibrary {

    /// ~/Documents/MeetingCapture (not created here).
    static func recordingsRoot() -> URL? {
        guard let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return documents.appendingPathComponent("MeetingCapture", isDirectory: true)
    }

    /// The `limit` most recent recording folders, newest first.
    static func recent(limit: Int) -> [RecordingEntry] {
        let fm = FileManager.default
        guard let root = recordingsRoot(),
              let items = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let entries: [RecordingEntry] = items.compactMap { url in
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .creationDateKey, .contentModificationDateKey,
            ])
            guard values?.isDirectory == true else { return nil }

            let audio = url.appendingPathComponent("audio.m4a")
            let transcript = url.appendingPathComponent("transcript.md")
            let hasAudio = fm.fileExists(atPath: audio.path)
            let hasTranscript = fm.fileExists(atPath: transcript.path)
            let hasRaw = fm.fileExists(atPath: url.appendingPathComponent("desktop.caf").path)
                || fm.fileExists(atPath: url.appendingPathComponent("mic.caf").path)
            // Only surface folders that actually look like recordings.
            guard hasAudio || hasTranscript || hasRaw else { return nil }

            let (parsedDate, title) = parseFolderName(url.lastPathComponent)
            let fileDate = values?.creationDate ?? values?.contentModificationDate ?? .distantPast
            let metadata = UploadStatusStore.readMetadata(folderURL: url)
            let minuteURL = metadata?.minuteURL.flatMap(URL.init(string:))

            return RecordingEntry(
                folderURL: url,
                title: metadata?.meetingTitle ?? title,
                date: metadata?.startedAt ?? parsedDate ?? fileDate,
                audioURL: hasAudio ? audio : nil,
                transcriptURL: hasTranscript ? transcript : nil,
                minuteURL: minuteURL,
                uploadStatus: metadata?.uploadStatus
            )
        }

        return Array(entries.sorted { $0.date > $1.date }.prefix(limit))
    }

    /// Parse "yyyy-MM-dd_HHmm[-title][-N]" into (date, title). Best-effort.
    static func parseFolderName(_ name: String) -> (Date?, String?) {
        let headAndTitle = name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let head = headAndTitle.first else {
            return (nil, name.isEmpty ? nil : name)
        }
        let timestamp = head.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard timestamp.count == 2 else {
            return legacyParseFolderName(name)
        }
        let dateParts = timestamp[0].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard dateParts.count == 3,
              let year = Int(dateParts[0]), let month = Int(dateParts[1]), let day = Int(dateParts[2]),
              timestamp[1].count == 4, let hhmm = Int(timestamp[1]) else {
            return legacyParseFolderName(name)
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hhmm / 100
        components.minute = hhmm % 100
        let date = Calendar(identifier: .gregorian).date(from: components)

        var titleParts = headAndTitle.count > 1
            ? headAndTitle[1].split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            : []
        if let last = titleParts.last, last.count <= 3, !last.isEmpty, last.allSatisfy(\.isNumber) {
            titleParts.removeLast()
        }
        let title = titleParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (date, title.isEmpty ? nil : title)
    }

    private static func legacyParseFolderName(_ name: String) -> (Date?, String?) {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              parts[3].count == 4, let hhmm = Int(parts[3]) else {
            return (nil, name.isEmpty ? nil : name)
        }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hhmm / 100
        components.minute = hhmm % 100
        let date = Calendar(identifier: .gregorian).date(from: components)

        var titleParts = Array(parts.dropFirst(4))
        if let last = titleParts.last, last.count <= 3, !last.isEmpty, last.allSatisfy(\.isNumber) {
            titleParts.removeLast()
        }
        let title = titleParts.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return (date, title.isEmpty ? nil : title)
    }
}
