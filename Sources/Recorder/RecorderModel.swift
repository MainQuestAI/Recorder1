import Foundation
import Observation
import AppKit

/// Owns every component and wires their callbacks. The model is @MainActor;
/// audio-thread callbacks hop to main via DispatchQueue.main.async before touching state.
@MainActor
@Observable
final class RecorderModel {

    // MARK: - Observable UI state

    var state: RecorderState = .idle
    var desktopLevel: Float = 0      // 0..1 meter (LEFT / desktop)
    var micLevel: Float = 0          // 0..1 meter (RIGHT / mic)
    var meetings: [Meeting] = []
    var currentSession: RecordingSession? = nil
    var elapsed: TimeInterval = 0
    var statusMessage: String? = nil

    // MARK: - Persisted preferences (mirrored to UserDefaults via Preferences)

    /// Your name — labels the local (mic / right-channel) voice in transcripts.
    /// Empty = omit. Replaces the old hardcoded speaker name.
    var localSpeakerName: String = "" {
        didSet { Preferences.speakerName = localSpeakerName }
    }
    /// Auto-stop after this many seconds of two-channel silence.
    var silenceTimeout: TimeInterval = 300 {
        didSet { Preferences.silenceTimeout = silenceTimeout }
    }
    /// dBFS below which a channel is considered silent.
    var silenceThresholdDB: Float = -50 {
        didSet { Preferences.silenceThresholdDB = silenceThresholdDB }
    }
    /// Whether silence auto-stop runs at all.
    var silenceAutoStopEnabled: Bool = true {
        didSet { Preferences.silenceAutoStop = silenceAutoStopEnabled }
    }
    /// Whether to transcribe automatically after a recording is saved.
    var autoTranscribe: Bool = true {
        didSet { Preferences.autoTranscribe = autoTranscribe }
    }

    // Transcription (post-save).
    var transcriptionState: TranscriptionState = .idle
    var lastTranscriptText: String? = nil
    var lastTranscriptURL: URL? = nil
    /// Whether a Gemini API key is available in the Keychain.
    var apiKeyIsSet: Bool = false

    /// The most recent recordings on disk (loaded at launch + after changes).
    var recentRecordings: [RecordingEntry] = []

    // MARK: - Heavy / audio objects (not observation-tracked)

    @ObservationIgnored private let tap = SystemAudioTap()
    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private let calendar = CalendarAccess()
    @ObservationIgnored private let notifications = NotificationManager()
    @ObservationIgnored private let transcriber = GeminiTranscriber()
    @ObservationIgnored private var silenceMonitor: SilenceMonitor?

    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var recordingStartedAt: Date?

    /// The meeting (if any) the current recording is attached to — kept so its
    /// title + attendees are available as transcription context at save time.
    @ObservationIgnored private var activeMeeting: Meeting?

    /// Everything needed to (re)run a transcription, captured at save time.
    private struct PendingTranscription {
        let audioURL: URL
        let folderURL: URL
        let meetingTitle: String?
        let attendees: [String]
        let startedAt: Date
    }
    @ObservationIgnored private var lastTranscription: PendingTranscription?

    // MARK: - Lifecycle

    func onAppear() {
        // Load persisted preferences first so the UI reflects them immediately.
        loadPreferences()

        // Seed the Keychain from GEMINI_API_KEY on first run (handy when the app is
        // launched from a shell that has the key exported; GUI launches won't inherit
        // it, so the Keychain is the durable store thereafter).
        if GeminiKeychain.read() == nil,
           let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"],
           !env.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            GeminiKeychain.save(env)
        }
        apiKeyIsSet = GeminiKeychain.read() != nil

        // Load prior recordings from disk so they survive restarts.
        refreshRecordings()

        // Request permissions concurrently, then load meetings.
        Task { @MainActor in
            _ = await MicCapture.requestAccess()
        }
        Task { @MainActor in
            _ = await calendar.requestAccess()
            refreshMeetings()
        }
        Task { @MainActor in
            await notifications.requestAuthorization()
        }

        // Refetch meetings on calendar changes.
        calendar.onChange = { [weak self] in
            // onChange is delivered on main (CalendarAccess is @MainActor).
            self?.refreshMeetings()
        }

        // A user tapping "Stop Recording" in the meeting-end notification stops + saves.
        notifications.onStopRequested = { [weak self] in
            guard let self else { return }
            if self.state != .idle {
                self.saveAndStop()
            }
        }

        // Surface fatal capture errors to the UI.
        tap.onFatalError = { [weak self] error in
            DispatchQueue.main.async {
                self?.statusMessage = "Desktop audio error: \(error.localizedDescription)"
            }
        }
        mic.onFatalError = { [weak self] error in
            DispatchQueue.main.async {
                self?.statusMessage = "Mic error: \(error.localizedDescription)"
            }
        }
    }

    /// Pull persisted preferences into the observable properties. The `didSet`
    /// write-backs are idempotent (same value in → same value out).
    private func loadPreferences() {
        localSpeakerName = Preferences.speakerName
        silenceTimeout = Preferences.silenceTimeout
        silenceThresholdDB = Preferences.silenceThresholdDB
        silenceAutoStopEnabled = Preferences.silenceAutoStop
        autoTranscribe = Preferences.autoTranscribe
    }

    // MARK: - Recording control

    func startRecording(meeting: Meeting?) {
        guard state == .idle else { return }

        let now = Date()
        let session: RecordingSession
        do {
            session = try RecordingSession.create(now: now, meetingTitle: meeting?.title)
        } catch {
            statusMessage = "Could not create recording folder: \(error.localizedDescription)"
            return
        }
        currentSession = session
        activeMeeting = meeting

        // Clear any previous recording's transcription UI.
        transcriptionState = .idle
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastTranscription = nil

        // Silence monitor (auto-stop after prolonged silence on both channels).
        // Only armed when the user has auto-stop enabled.
        if silenceAutoStopEnabled {
            silenceMonitor = SilenceMonitor(
                thresholdDB: silenceThresholdDB,
                timeout: silenceTimeout,
                onTimeout: { [weak self] in
                    // onTimeout is invoked on MAIN per contract.
                    self?.saveAndStop()
                }
            )
        } else {
            silenceMonitor = nil
        }

        // Wire level callbacks (called on audio threads -> hop to main).
        tap.onLevelDB = { [weak self] db in
            DispatchQueue.main.async {
                guard let self else { return }
                self.desktopLevel = meterLevel(fromDB: db)
                self.silenceMonitor?.noteLevel(db)
            }
        }
        mic.onLevelDB = { [weak self] db in
            DispatchQueue.main.async {
                guard let self else { return }
                self.micLevel = meterLevel(fromDB: db)
                self.silenceMonitor?.noteLevel(db)
            }
        }

        // Start both captures.
        do {
            try tap.start(writingTo: session.desktopURL)
            try mic.start(writingTo: session.micURL)
        } catch {
            statusMessage = "Could not start capture: \(error.localizedDescription)"
            _ = tap.stop()
            _ = mic.stop()
            currentSession = nil
            silenceMonitor = nil
            return
        }

        silenceMonitor?.start()

        // Schedule a meeting-end alert when recording a known meeting.
        if let meeting {
            notifications.scheduleMeetingEndAlert(at: meeting.end, meetingTitle: meeting.title)
        }

        state = .recording
        statusMessage = nil
        startElapsedTimer(from: now)
    }

    func togglePause() {
        switch state {
        case .recording:
            tap.setPaused(true)
            mic.setPaused(true)
            silenceMonitor?.stop()
            state = .paused
        case .paused:
            tap.setPaused(false)
            mic.setPaused(false)
            silenceMonitor?.start()
            state = .recording
        case .idle:
            break
        }
    }

    func saveAndStop() {
        guard state != .idle, let session = currentSession else {
            resetToIdle()
            return
        }

        let desktopResult = tap.stop()
        let micResult = mic.stop()

        cancelTimersAndAlerts()
        state = .idle
        statusMessage = "Mixing…"

        // Mix off the main actor; keep raw CAFs regardless of outcome.
        let outputURL = session.outputURL
        let desktopURL = session.desktopURL
        let micURL = session.micURL
        let folderURL = session.folderURL
        let startedAt = session.startedAt
        let meetingTitle = activeMeeting?.title ?? session.meetingTitle
        let attendees = activeMeeting?.attendees ?? []
        Task.detached(priority: .utility) {
            do {
                try StereoMixer.mix(
                    desktopURL: desktopURL,
                    micURL: micURL,
                    desktopResult: desktopResult,
                    micResult: micResult,
                    outputURL: outputURL
                )
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let pending = PendingTranscription(
                        audioURL: outputURL,
                        folderURL: folderURL,
                        meetingTitle: meetingTitle,
                        attendees: attendees,
                        startedAt: startedAt
                    )
                    if self.autoTranscribe {
                        self.statusMessage = "Saved \(outputURL.lastPathComponent)"
                        // Chain transcription off the successful mix.
                        self.startTranscription(pending)
                    } else {
                        // Auto-transcribe off: keep the recording; the user can
                        // transcribe it later from the Recent list.
                        self.lastTranscription = pending
                        self.transcriptionState = .idle
                        self.statusMessage = "Saved \(outputURL.lastPathComponent) · transcription off"
                    }
                    self.refreshRecordings()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.statusMessage = "Mix failed (raw files kept): \(error.localizedDescription)"
                }
            }
        }

        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
    }

    func trashAndStop() {
        guard state != .idle else {
            resetToIdle()
            return
        }

        _ = tap.stop()
        _ = mic.stop()

        cancelTimersAndAlerts()

        if let session = currentSession {
            try? FileManager.default.removeItem(at: session.folderURL)
        }

        state = .idle
        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
        statusMessage = "Discarded"
        transcriptionState = .idle
        lastTranscriptText = nil
        lastTranscriptURL = nil
        lastTranscription = nil
        refreshRecordings()
    }

    func refreshMeetings() {
        let now = Date()
        meetings = calendar.meetingsAroundNow(now)
    }

    /// The meeting currently in progress, if any. All-day events are already
    /// excluded from `meetings`, so this only matches timed meetings. Used as the
    /// default target for the main Record button so recording while you're in a
    /// meeting auto-tags it (folder name + end alert + transcription context).
    var currentMeeting: Meeting? {
        let now = Date()
        return meetings.first(where: { $0.isInProgress(now) })
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func startElapsedTimer(from start: Date) {
        recordingStartedAt = start
        elapsed = 0
        elapsedTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, let started = self.recordingStartedAt else { return }
                if self.state == .recording {
                    self.elapsed = Date().timeIntervalSince(started)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    private func cancelTimersAndAlerts() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingStartedAt = nil
        silenceMonitor?.stop()
        notifications.cancelMeetingEndAlert()
    }

    private func resetToIdle() {
        cancelTimersAndAlerts()
        state = .idle
        currentSession = nil
        activeMeeting = nil
        silenceMonitor = nil
        elapsed = 0
    }

    // MARK: - Transcription

    /// Resolve the Gemini key: Keychain first, then the process environment.
    private func resolvedAPIKey() -> String? {
        if let stored = GeminiKeychain.read() { return stored }
        if let env = ProcessInfo.processInfo.environment["GEMINI_API_KEY"] {
            let trimmed = env.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Save/replace the Gemini API key in the Keychain. If a transcription was
    /// waiting on a key, it starts immediately.
    func saveAPIKey(_ raw: String) {
        guard GeminiKeychain.save(raw) else {
            statusMessage = "Could not store the API key in the Keychain."
            return
        }
        apiKeyIsSet = true
        statusMessage = "API key saved"
        if case .failed = transcriptionState, let pending = lastTranscription {
            startTranscription(pending)
        }
    }

    /// Remove the stored Gemini API key.
    func clearAPIKey() {
        GeminiKeychain.delete()
        apiKeyIsSet = false
        statusMessage = "API key removed"
    }

    /// Re-run the last transcription (after a failure or a freshly entered key).
    func retryTranscription() {
        guard let pending = lastTranscription else { return }
        startTranscription(pending)
    }

    private func startTranscription(_ pending: PendingTranscription) {
        lastTranscription = pending
        lastTranscriptText = nil
        lastTranscriptURL = nil

        guard let key = resolvedAPIKey() else {
            transcriptionState = .failed("No Gemini API key set — add one in Settings to transcribe.")
            statusMessage = "Saved (no API key — transcription skipped)"
            return
        }

        transcriptionState = .running
        statusMessage = "Transcribing…"

        let transcriber = self.transcriber
        let trimmedName = localSpeakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = GeminiTranscriber.Context(
            meetingTitle: pending.meetingTitle,
            attendees: pending.attendees,
            startedAt: pending.startedAt,
            localSpeakerName: trimmedName.isEmpty ? nil : trimmedName
        )

        Task { [weak self] in
            do {
                let markdown = try await transcriber.transcribe(
                    audioURL: pending.audioURL,
                    apiKey: key,
                    context: context
                )
                let document = RecorderModel.composeTranscriptDocument(
                    markdown: markdown,
                    meetingTitle: pending.meetingTitle,
                    attendees: pending.attendees,
                    startedAt: pending.startedAt,
                    audioName: pending.audioURL.lastPathComponent,
                    model: transcriber.model
                )
                let transcriptURL = pending.folderURL.appendingPathComponent("transcript.md")
                try document.write(to: transcriptURL, atomically: true, encoding: .utf8)
                await MainActor.run {
                    guard let self else { return }
                    self.lastTranscriptText = document
                    self.lastTranscriptURL = transcriptURL
                    self.transcriptionState = .done(transcriptURL)
                    self.statusMessage = "Transcript saved (transcript.md)"
                    self.refreshRecordings()
                }
            } catch {
                let message = RecorderModel.describeTranscriptionError(error)
                await MainActor.run {
                    guard let self else { return }
                    self.transcriptionState = .failed(message)
                    self.statusMessage = "Transcription failed"
                }
            }
        }
    }

    /// Copy the transcript text to the clipboard.
    func copyTranscriptText() {
        guard let text = lastTranscriptText else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Transcript text copied"
    }

    /// Copy the transcript *file* to the clipboard (paste into Finder / Mail / etc.).
    func copyTranscriptFile() {
        guard let url = lastTranscriptURL else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        statusMessage = "Transcript file copied"
    }

    /// Reveal the transcript in Finder.
    func revealTranscript() {
        guard let url = lastTranscriptURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - Recordings library

    /// Reload the recent-recordings list from disk.
    func refreshRecordings() {
        recentRecordings = RecordingsLibrary.recent(limit: 4)
    }

    /// Transcribe (or re-transcribe) an existing recording's audio.
    func transcribeExisting(_ entry: RecordingEntry) {
        guard let audio = entry.audioURL else {
            statusMessage = "No audio.m4a to transcribe in that folder."
            return
        }
        startTranscription(PendingTranscription(
            audioURL: audio,
            folderURL: entry.folderURL,
            meetingTitle: entry.title,
            attendees: [],
            startedAt: entry.date
        ))
    }

    /// Put a file on the clipboard (paste into Finder / Mail / …).
    func copyFileToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        statusMessage = "Copied \(url.lastPathComponent)"
    }

    /// Put a text file's contents on the clipboard.
    func copyTextOfFile(_ url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = "Could not read \(url.lastPathComponent)"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        statusMessage = "Copied text of \(url.lastPathComponent)"
    }

    /// Reveal an arbitrary file/folder in Finder.
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open ~/Documents/Recordings in Finder (creating it if needed).
    func openRecordingsFolder() {
        guard let root = RecordingsLibrary.recordingsRoot() else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    /// Wrap the model's Markdown with a small header (title / date / attendees).
    private static func composeTranscriptDocument(
        markdown: String,
        meetingTitle: String?,
        attendees: [String],
        startedAt: Date,
        audioName: String,
        model: String
    ) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short

        var header = "# Transcript"
        if let title = meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            header += " — \(title)"
        }

        var lines = [header, ""]
        lines.append("- **Recorded:** \(formatter.string(from: startedAt))")
        if !attendees.isEmpty {
            lines.append("- **Invited attendees:** \(attendees.joined(separator: ", "))")
        }
        lines.append("- **Audio:** `\(audioName)`")
        lines.append("- **Model:** Gemini `\(model)`")
        lines.append("")
        lines.append("> Channel layout — left = desktop/system audio, right = microphone.")
        lines.append("")
        lines.append("---")
        lines.append("")
        lines.append(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func describeTranscriptionError(_ error: Error) -> String {
        if let e = error as? GeminiTranscriber.TranscriberError {
            return e.errorDescription ?? "Transcription failed."
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "Network error: \(ns.localizedDescription)"
        }
        return error.localizedDescription
    }
}
