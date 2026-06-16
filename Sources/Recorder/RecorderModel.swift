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
    /// Empty means auto-resolve lark-cli from known Homebrew/npm locations and PATH.
    var larkCLIPath: String = "" {
        didSet { Preferences.larkCLIPath = larkCLIPath }
    }
    /// Whether to upload automatically after audio.m4a is saved.
    var autoUploadAfterSave: Bool = true {
        didSet { Preferences.autoUploadAfterSave = autoUploadAfterSave }
    }
    var fetchNotesAfterUpload: Bool = true {
        didSet { Preferences.fetchNotesAfterUpload = fetchNotesAfterUpload }
    }
    var copyMinuteURLAfterUpload: Bool = false {
        didSet { Preferences.copyMinuteURLAfterUpload = copyMinuteURLAfterUpload }
    }
    var openMinuteURLAfterUpload: Bool = false {
        didSet { Preferences.openMinuteURLAfterUpload = openMinuteURLAfterUpload }
    }

    // Feishu upload (post-save).
    var uploadState: UploadState = .idle
    var lastMinuteURL: URL? = nil

    /// The most recent recordings on disk (loaded at launch + after changes).
    var recentRecordings: [RecordingEntry] = []

    // MARK: - Heavy / audio objects (not observation-tracked)

    @ObservationIgnored private let tap = SystemAudioTap()
    @ObservationIgnored private let mic = MicCapture()
    @ObservationIgnored private let calendar = CalendarAccess()
    @ObservationIgnored private let notifications = NotificationManager()
    @ObservationIgnored private var silenceMonitor: SilenceMonitor?

    @ObservationIgnored private var elapsedTimer: Timer?
    @ObservationIgnored private var recordingStartedAt: Date?

    /// The meeting (if any) the current recording is attached to.
    @ObservationIgnored private var activeMeeting: Meeting?

    /// Everything needed to retry a Feishu upload, captured at save time.
    @ObservationIgnored private var lastUploadJob: FeishuUploadJob?
    @ObservationIgnored private var preparingToRecord = false

    // MARK: - Lifecycle

    func onAppear() {
        // Load persisted preferences first so the UI reflects them immediately.
        loadPreferences()

        // Load prior recordings from disk so they survive restarts.
        refreshRecordings()

        // Request calendar access and load meetings. Microphone permission is
        // requested only when the user starts recording so the system prompt is
        // tied to an explicit action.
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
        silenceTimeout = Preferences.silenceTimeout
        silenceThresholdDB = Preferences.silenceThresholdDB
        silenceAutoStopEnabled = Preferences.silenceAutoStop
        larkCLIPath = Preferences.larkCLIPath
        autoUploadAfterSave = Preferences.autoUploadAfterSave
        fetchNotesAfterUpload = Preferences.fetchNotesAfterUpload
        copyMinuteURLAfterUpload = Preferences.copyMinuteURLAfterUpload
        openMinuteURLAfterUpload = Preferences.openMinuteURLAfterUpload
    }

    // MARK: - Recording control

    func startRecording(meeting: Meeting?) {
        guard state == .idle, !preparingToRecord else { return }
        preparingToRecord = true
        statusMessage = "Checking microphone permission..."
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let micAllowed = await MicCapture.requestAccess()
            guard micAllowed else {
                self.preparingToRecord = false
                self.statusMessage = "Microphone permission is required. Allow it in System Settings."
                return
            }
            self.preparingToRecord = false
            self.beginRecording(meeting: meeting)
        }
    }

    private func beginRecording(meeting: Meeting?) {
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
        UploadStatusStore.writeInitial(session: session, meeting: meeting)

        // Clear any previous recording's upload UI.
        uploadState = .idle
        lastMinuteURL = nil
        lastUploadJob = nil

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
            UploadStatusStore.markCaptureFailed(session: session, meeting: meeting, error: error)
            currentSession = nil
            activeMeeting = nil
            silenceMonitor = nil
            refreshRecordings()
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
        let endedAt = Date()
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
                let audioQuality = try? AudioQualityAnalyzer.analyze(audioURL: outputURL)
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let job = FeishuUploadJob(
                        audioURL: outputURL,
                        folderURL: folderURL,
                        meetingTitle: meetingTitle,
                        attendees: attendees,
                        startedAt: startedAt,
                        endedAt: endedAt
                    )
                    UploadStatusStore.markSaved(job: job)
                    if let audioQuality {
                        UploadStatusStore.markAudioQuality(folderURL: folderURL, report: audioQuality)
                    }
                    self.lastUploadJob = job
                    if self.autoUploadAfterSave {
                        self.statusMessage = "Saved \(outputURL.lastPathComponent)"
                        self.startUpload(job)
                    } else {
                        self.uploadState = .idle
                        self.statusMessage = "Saved \(outputURL.lastPathComponent) · auto upload off"
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
        uploadState = .idle
        lastMinuteURL = nil
        lastUploadJob = nil
        refreshRecordings()
    }

    func refreshMeetings() {
        let now = Date()
        meetings = calendar.meetingsAroundNow(now)
    }

    /// The meeting currently in progress, if any. All-day events are already
    /// excluded from `meetings`, so this only matches timed meetings. Used as the
    /// default target for the main Record button so recording while you're in a
    /// meeting auto-tags it (folder name + end alert + metadata context).
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

    // MARK: - Feishu upload

    func retryUpload() {
        guard let job = lastUploadJob else {
            statusMessage = "No saved audio.m4a to upload."
            return
        }
        startUpload(job)
    }

    func uploadExisting(_ entry: RecordingEntry) {
        guard let audio = entry.audioURL else {
            statusMessage = "No audio.m4a in that folder."
            return
        }
        let metadata = UploadStatusStore.readMetadata(folderURL: entry.folderURL)
        let job = FeishuUploadJob(
            audioURL: audio,
            folderURL: entry.folderURL,
            meetingTitle: metadata?.meetingTitle ?? entry.title,
            attendees: metadata?.attendees ?? [],
            startedAt: metadata?.startedAt ?? entry.date,
            endedAt: metadata?.endedAt ?? Date()
        )
        startUpload(job)
    }

    private func startUpload(_ job: FeishuUploadJob) {
        lastUploadJob = job
        uploadState = .running
        lastMinuteURL = nil
        statusMessage = "Uploading to Feishu..."

        let cliPath = larkCLIPath
        let fetchNotes = fetchNotesAfterUpload
        let shouldCopy = copyMinuteURLAfterUpload
        let shouldOpen = openMinuteURLAfterUpload

        Task { [weak self] in
            do {
                let uploader = FeishuCLIUploader(cliPath: cliPath, fetchNotes: fetchNotes)
                let result = try await uploader.upload(job: job)
                await MainActor.run {
                    guard let self else { return }
                    self.lastMinuteURL = result.minuteURL
                    self.uploadState = .uploaded(result.minuteURL)
                    self.statusMessage = "Uploaded to Feishu Minutes"
                    if shouldCopy {
                        self.copyMinuteURL(result.minuteURL)
                    }
                    if shouldOpen {
                        NSWorkspace.shared.open(result.minuteURL)
                    }
                    self.refreshRecordings()
                }
            } catch {
                let message = RecorderModel.describeUploadError(error)
                UploadStatusStore.markFailed(job: job, error: error)
                await MainActor.run {
                    guard let self else { return }
                    self.uploadState = .failed(message)
                    self.statusMessage = "Upload failed"
                    self.refreshRecordings()
                }
            }
        }
    }

    func copyCurrentMinuteURL() {
        guard let url = lastMinuteURL else { return }
        copyMinuteURL(url)
    }

    func openCurrentMinuteURL() {
        guard let url = lastMinuteURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyMinuteURL(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
        statusMessage = "Minute URL copied"
    }

    func openMinuteURL(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealLastUploadFolder() {
        guard let folderURL = lastUploadJob?.folderURL else { return }
        reveal(folderURL)
    }

    // MARK: - Recordings library

    /// Reload the recent-recordings list from disk.
    func refreshRecordings() {
        recentRecordings = RecordingsLibrary.recent(limit: 4)
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

    /// Open ~/Documents/MeetingCapture in Finder (creating it if needed).
    func openRecordingsFolder() {
        guard let root = RecordingsLibrary.recordingsRoot() else { return }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
    }

    private static func describeUploadError(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return "Network error: \(ns.localizedDescription)"
        }
        return error.localizedDescription
    }
}
