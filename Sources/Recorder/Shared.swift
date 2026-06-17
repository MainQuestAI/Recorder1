import Foundation
import AVFoundation

enum RecorderPaths {
    static let recordingsFolderName = "Recorder1"

    static func recordingsRoot(create: Bool) throws -> URL {
        let fm = FileManager.default
        let documents = try fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let root = documents.appendingPathComponent(recordingsFolderName, isDirectory: true)

        if create {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }
}

// MARK: - RecorderState

enum RecorderState: Equatable {
    case idle
    case recording
    case paused
}

// MARK: - UploadState

/// Post-save Feishu upload progress, surfaced in the panel.
enum UploadState: Equatable {
    case idle
    /// Saved audio is likely incomplete; user must confirm before upload.
    case needsConfirmation(String)
    case running
    /// Feishu Minutes URL.
    case uploaded(URL)
    /// Failed with a user-facing message.
    case failed(String)
}

// MARK: - CaptureResult

/// Returned by a capture's `stop()`.
struct CaptureResult {
    /// mach host time (mach_absolute_time domain) of the FIRST sample written; nil if nothing captured.
    var firstHostTime: UInt64?
    /// actual capture sample rate.
    var sampleRate: Double
    /// number of audio frames written.
    var frameCount: AVAudioFramePosition
    /// Optional desktop/system-audio capture metadata. Mic captures leave this nil.
    var systemAudio: SystemAudioCaptureMetadata?

    init(
        firstHostTime: UInt64? = nil,
        sampleRate: Double = 0,
        frameCount: AVAudioFramePosition = 0,
        systemAudio: SystemAudioCaptureMetadata? = nil
    ) {
        self.firstHostTime = firstHostTime
        self.sampleRate = sampleRate
        self.frameCount = frameCount
        self.systemAudio = systemAudio
    }
}

// MARK: - Meeting

struct Meeting: Identifiable, Equatable {
    /// EKEvent.eventIdentifier (or a synthesized uuid).
    let id: String
    let title: String
    let start: Date
    let end: Date
    /// Display names of the organizer + invitees (best-effort; may be empty).
    /// Stored in metadata so the recording keeps useful meeting context.
    let attendees: [String]

    init(id: String, title: String, start: Date, end: Date, attendees: [String] = []) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.attendees = attendees
    }

    /// start <= now <= end
    func isInProgress(_ now: Date) -> Bool {
        start <= now && now <= end
    }

    /// Filesystem-safe suffix derived from the title.
    var folderSuffix: String {
        Meeting.sanitize(title)
    }

    /// Make a title filesystem-safe:
    /// - strip `/ : \ ? % * | " < >` and control characters
    /// - collapse runs of whitespace to a single `-`
    /// - cap to ~40 characters
    /// - trim leading `.`/`-`
    /// - empty result -> "meeting"
    static func sanitize(_ raw: String) -> String {
        let illegal: Set<Character> = ["/", ":", "\\", "?", "%", "*", "|", "\"", "<", ">"]

        // Remove illegal + control characters.
        var cleaned = ""
        cleaned.reserveCapacity(raw.count)
        for ch in raw {
            if illegal.contains(ch) { continue }
            if ch.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { continue }
            cleaned.append(ch)
        }

        // Collapse whitespace runs to a single dash.
        let pieces = cleaned.split(whereSeparator: { $0.isWhitespace })
        var collapsed = pieces.joined(separator: "-")

        // Cap length to ~40 chars.
        if collapsed.count > 40 {
            collapsed = String(collapsed.prefix(40))
        }

        // Trim leading '.' and '-' (avoid hidden / odd folder names).
        while let first = collapsed.first, first == "." || first == "-" {
            collapsed.removeFirst()
        }
        // Also trim trailing dashes left over from capping/collapsing.
        while let last = collapsed.last, last == "-" {
            collapsed.removeLast()
        }

        return collapsed.isEmpty ? "meeting" : collapsed
    }
}

// MARK: - RecordingSession

enum RecordingTitleSource: String, Codable, Equatable {
    case calendar
    case manual
    case fallback
}

struct RecordingTitleDraft: Equatable {
    var title: String
    var source: RecordingTitleSource
    var linkedMeeting: Meeting?
    var userEdited: Bool

    static var empty: RecordingTitleDraft {
        RecordingTitleDraft(
            title: "",
            source: .fallback,
            linkedMeeting: nil,
            userEdited: false
        )
    }
}

struct RecordingSession {
    /// ~/Documents/Recorder1/{yyyy-MM-dd_HHmm}[-suffix]/
    let folderURL: URL
    /// folderURL + "desktop.caf"
    let desktopURL: URL
    /// folderURL + "mic.caf"
    let micURL: URL
    /// folderURL + "audio.m4a"
    let outputURL: URL
    let startedAt: Date
    let meetingTitle: String?
    let titleSource: RecordingTitleSource
    let calendarEventTitle: String?

    /// Creates the dated folder and returns the session. Throws on filesystem error.
    static func create(
        now: Date,
        meetingTitle: String?,
        titleSource: RecordingTitleSource = .fallback,
        calendarEventTitle: String? = nil
    ) throws -> RecordingSession {
        let fm = FileManager.default

        let recordingsRoot = try RecorderPaths.recordingsRoot(create: true)

        let dateFmt = DateFormatter()
        dateFmt.locale = Locale(identifier: "en_US_POSIX")
        dateFmt.calendar = Calendar(identifier: .gregorian)
        dateFmt.dateFormat = "yyyy-MM-dd"

        let timeFmt = DateFormatter()
        timeFmt.locale = Locale(identifier: "en_US_POSIX")
        timeFmt.calendar = Calendar(identifier: .gregorian)
        timeFmt.dateFormat = "HHmm"

        var folderName = "\(dateFmt.string(from: now))_\(timeFmt.string(from: now))"
        if let title = meetingTitle {
            folderName += "-\(Meeting.sanitize(title))"
        }

        var folderURL = recordingsRoot.appendingPathComponent(folderName, isDirectory: true)
        // Avoid clobbering a prior recording made in the same minute (e.g. save-then-record
        // again, or a meeting whose sanitized title matches): if the folder already exists,
        // pick the next free `-N` suffix so we never overwrite existing raw files.
        if fm.fileExists(atPath: folderURL.path) {
            var n = 2
            var candidate = recordingsRoot.appendingPathComponent("\(folderName)-\(n)", isDirectory: true)
            while fm.fileExists(atPath: candidate.path) {
                n += 1
                candidate = recordingsRoot.appendingPathComponent("\(folderName)-\(n)", isDirectory: true)
            }
            folderURL = candidate
        }
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        return RecordingSession(
            folderURL: folderURL,
            desktopURL: folderURL.appendingPathComponent("desktop.caf"),
            micURL: folderURL.appendingPathComponent("mic.caf"),
            outputURL: folderURL.appendingPathComponent("audio.m4a"),
            startedAt: now,
            meetingTitle: meetingTitle,
            titleSource: titleSource,
            calendarEventTitle: calendarEventTitle
        )
    }
}

// MARK: - Meter mapping

/// dBFS (-inf..0) -> normalized meter 0...1 for the UI.
func meterLevel(fromDB db: Float) -> Float {
    max(0, min(1, (db + 80) / 80))
}
