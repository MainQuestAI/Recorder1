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
    var detectedMeeting: Meeting? = nil
    var recordingTitleDraft: RecordingTitleDraft = .empty
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
    var language: AppLanguage = .zh {
        didSet { Preferences.language = language }
    }
    var preferredInputDeviceUID: String = "" {
        didSet { Preferences.preferredInputDeviceUID = preferredInputDeviceUID }
    }
    var recordingRetentionPolicy: RecordingRetentionPolicy = .keepForever {
        didSet {
            Preferences.recordingRetentionPolicy = recordingRetentionPolicy
            if !loadingPreferences {
                runLocalCleanup(showStatus: true)
            }
        }
    }
    var inputDevices: [AudioInputDeviceInfo] = []

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
    @ObservationIgnored private var loadingPreferences = false

    // MARK: - Lifecycle

    func onAppear() {
        // Load persisted preferences first so the UI reflects them immediately.
        loadPreferences()

        // Load prior recordings from disk so they survive restarts.
        runLocalCleanup(showStatus: false)
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
                self?.statusMessage = self?.text("status.desktopError", error.localizedDescription)
            }
        }
        tap.onRouteChanged = { [weak self] event in
            DispatchQueue.main.async {
                guard let self, let session = self.currentSession else { return }
                UploadStatusStore.markRouteChanged(folderURL: session.folderURL, event: event)
            }
        }
        tap.onCaptureFailed = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self, let session = self.currentSession else { return }
                UploadStatusStore.markSystemAudioCaptureFailed(folderURL: session.folderURL, reason: reason)
                self.statusMessage = self.text("status.systemAudioSilent")
            }
        }
        mic.onFatalError = { [weak self] error in
            DispatchQueue.main.async {
                self?.statusMessage = self?.text("status.micError", error.localizedDescription)
            }
        }
    }

    /// Pull persisted preferences into the observable properties. The `didSet`
    /// write-backs are idempotent (same value in → same value out).
    private func loadPreferences() {
        loadingPreferences = true
        defer { loadingPreferences = false }

        silenceTimeout = Preferences.silenceTimeout
        silenceThresholdDB = Preferences.silenceThresholdDB
        silenceAutoStopEnabled = Preferences.silenceAutoStop
        larkCLIPath = Preferences.larkCLIPath
        autoUploadAfterSave = Preferences.autoUploadAfterSave
        fetchNotesAfterUpload = Preferences.fetchNotesAfterUpload
        copyMinuteURLAfterUpload = Preferences.copyMinuteURLAfterUpload
        openMinuteURLAfterUpload = Preferences.openMinuteURLAfterUpload
        language = Preferences.language
        preferredInputDeviceUID = Preferences.preferredInputDeviceUID
        recordingRetentionPolicy = Preferences.recordingRetentionPolicy
        refreshInputDevices()
    }

    // MARK: - Recording control

    private struct ResolvedRecordingTitle {
        var title: String
        var source: RecordingTitleSource
        var linkedMeeting: Meeting?
        var calendarEventTitle: String?
    }

    func startRecording(meeting: Meeting?, matchCurrentMeeting: Bool = true) {
        guard state == .idle, !preparingToRecord else { return }
        if let meeting {
            useMeetingForRecordingTitle(meeting)
        }
        preparingToRecord = true
        statusMessage = text("status.checkingMic")
        NSApp.activate(ignoringOtherApps: true)

        Task { @MainActor [weak self] in
            guard let self else { return }
            let micAllowed = await MicCapture.requestAccess()
            guard micAllowed else {
                self.preparingToRecord = false
                self.statusMessage = self.text("status.micPermissionRequired")
                return
            }
            self.refreshInputDevices()
            self.preparingToRecord = false
            let resolvedTitle = self.resolveRecordingTitleForStart(matchCurrentMeeting: matchCurrentMeeting && meeting == nil)
            self.beginRecording(titleContext: resolvedTitle)
        }
    }

    func startRecordingWithoutMeeting() {
        guard state == .idle else { return }
        let manualTitle = recordingTitleDraft.userEdited ? recordingTitleDraft.title : ""
        recordingTitleDraft = RecordingTitleDraft(
            title: manualTitle,
            source: manualTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .fallback : .manual,
            linkedMeeting: nil,
            userEdited: recordingTitleDraft.userEdited
        )
        startRecording(meeting: nil, matchCurrentMeeting: false)
    }

    private func beginRecording(titleContext: ResolvedRecordingTitle) {
        guard state == .idle else { return }

        let now = Date()
        let session: RecordingSession
        do {
            session = try RecordingSession.create(
                now: now,
                meetingTitle: titleContext.title,
                titleSource: titleContext.source,
                calendarEventTitle: titleContext.calendarEventTitle
            )
        } catch {
            statusMessage = text("status.createFolderFailed", error.localizedDescription)
            return
        }
        currentSession = session
        activeMeeting = titleContext.linkedMeeting
        UploadStatusStore.writeInitial(session: session, meeting: titleContext.linkedMeeting)

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
            try mic.start(
                writingTo: session.micURL,
                preferredInputDeviceUID: preferredInputDeviceUID.isEmpty ? nil : preferredInputDeviceUID
            )
            UploadStatusStore.markMicrophoneInput(folderURL: session.folderURL, device: mic.activeInputDevice)
        } catch {
            statusMessage = text("status.captureStartFailed", describeCaptureError(error))
            _ = tap.stop()
            _ = mic.stop()
            UploadStatusStore.markCaptureFailed(session: session, meeting: titleContext.linkedMeeting, error: error)
            currentSession = nil
            activeMeeting = nil
            silenceMonitor = nil
            refreshRecordings()
            return
        }

        silenceMonitor?.start()

        // Schedule a meeting-end alert when recording a known meeting.
        if let meeting = titleContext.linkedMeeting {
            notifications.scheduleMeetingEndAlert(at: meeting.end, meetingTitle: meeting.title, language: language)
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
        statusMessage = text("status.mixing")

        // Mix off the main actor; keep raw CAFs regardless of outcome.
        let outputURL = session.outputURL
        let desktopURL = session.desktopURL
        let micURL = session.micURL
        let folderURL = session.folderURL
        let startedAt = session.startedAt
        let endedAt = Date()
        let meetingTitle = session.meetingTitle ?? activeMeeting?.title
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
                        titleSource: session.titleSource,
                        calendarEventTitle: session.calendarEventTitle,
                        attendees: attendees,
                        startedAt: startedAt,
                        endedAt: endedAt
                    )
                    UploadStatusStore.markSaved(job: job)
                    UploadStatusStore.markSystemAudioCapture(folderURL: folderURL, metadata: desktopResult.systemAudio)
                    if let audioQuality {
                        UploadStatusStore.markAudioQuality(folderURL: folderURL, report: audioQuality)
                    }
                    let integrity = audioQuality.map { RecorderModel.captureIntegrity(for: $0) } ?? .passed()
                    UploadStatusStore.markCaptureIntegrity(folderURL: folderURL, integrity: integrity)
                    self.lastUploadJob = job
                    if integrity.requiresUploadConfirmation {
                        self.uploadState = .needsConfirmation(
                            self.text("capture.degraded")
                        )
                        self.statusMessage = self.text("status.savedSystemMissing", outputURL.lastPathComponent)
                    } else if self.autoUploadAfterSave {
                        self.statusMessage = self.text("status.saved", outputURL.lastPathComponent)
                        self.startUpload(job)
                    } else {
                        self.uploadState = .idle
                        self.statusMessage = self.text("status.savedAutoOff", outputURL.lastPathComponent)
                    }
                    self.refreshRecordings()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.statusMessage = self?.text("status.mixFailed", error.localizedDescription)
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
        statusMessage = text("status.discarded")
        uploadState = .idle
        lastMinuteURL = nil
        lastUploadJob = nil
        refreshRecordings()
    }

    func refreshMeetings() {
        let now = Date()
        meetings = calendar.meetingsAroundNow(now)
        detectedMeeting = calendar.currentMeeting(now)
        syncRecordingTitleWithDetectedMeeting()
    }

    /// Best detected meeting for the main Record button. CalendarAccess prefers
    /// an in-progress event, then the most recent started event, then the next one.
    var currentMeeting: Meeting? {
        detectedMeeting
    }

    var recordingTitleSourceLabel: String? {
        switch recordingTitleDraft.source {
        case .calendar:
            return recordingTitleDraft.linkedMeeting == nil ? nil : text("title.source.calendar")
        case .manual:
            return recordingTitleDraft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : text("title.source.manual")
        case .fallback:
            return nil
        }
    }

    func updateRecordingTitle(_ title: String) {
        recordingTitleDraft.title = title
        recordingTitleDraft.source = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .fallback
            : .manual
        recordingTitleDraft.userEdited = true
    }

    func useMeetingForRecordingTitle(_ meeting: Meeting) {
        recordingTitleDraft = RecordingTitleDraft(
            title: meeting.title,
            source: .calendar,
            linkedMeeting: meeting,
            userEdited: false
        )
        detectedMeeting = meeting
    }

    private func syncRecordingTitleWithDetectedMeeting() {
        guard state == .idle, !recordingTitleDraft.userEdited else { return }
        if let detectedMeeting {
            useMeetingForRecordingTitle(detectedMeeting)
        } else if recordingTitleDraft.source == .calendar {
            recordingTitleDraft = .empty
        }
    }

    private func resolveRecordingTitleForStart(matchCurrentMeeting: Bool) -> ResolvedRecordingTitle {
        if matchCurrentMeeting {
            let current = calendar.currentMeeting(Date())
            detectedMeeting = current
            if let current {
                if recordingTitleDraft.userEdited {
                    if recordingTitleDraft.linkedMeeting == nil {
                        recordingTitleDraft.linkedMeeting = current
                    }
                } else {
                    useMeetingForRecordingTitle(current)
                }
            }
        }

        let trimmedTitle = recordingTitleDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty ? "Recorder1" : trimmedTitle
        let source: RecordingTitleSource = trimmedTitle.isEmpty ? .fallback : recordingTitleDraft.source
        let linkedMeeting = recordingTitleDraft.linkedMeeting

        return ResolvedRecordingTitle(
            title: finalTitle,
            source: source,
            linkedMeeting: linkedMeeting,
            calendarEventTitle: linkedMeeting?.title
        )
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    func text(_ key: String, _ values: CVarArg...) -> String {
        let format = AppText.t(key, language)
        guard !values.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: values)
    }

    func refreshInputDevices() {
        inputDevices = AudioDeviceCatalog.inputDevices()
        if !preferredInputDeviceUID.isEmpty,
           !inputDevices.contains(where: { $0.uid == preferredInputDeviceUID }) {
            preferredInputDeviceUID = ""
        }
    }

    var selectedInputDeviceDisplayName: String {
        if let selected = inputDevices.first(where: { $0.uid == preferredInputDeviceUID }) {
            return selected.name
        }
        return AudioDeviceCatalog.defaultInputDevice()?.name ?? text("microphone.systemDefault")
    }

    private func runLocalCleanup(showStatus: Bool) {
        let result = RecordingCleanup.deleteExpiredUploadedRecordings(policy: recordingRetentionPolicy)
        guard result.deletedCount > 0 || result.failedCount > 0 else { return }
        refreshRecordings()
        if showStatus, result.deletedCount > 0 {
            statusMessage = text("status.cleanupDeleted", result.deletedCount)
        }
    }

    private func describeCaptureError(_ error: Error) -> String {
        if let micError = error as? MicCapture.MicError {
            switch micError {
            case .couldNotCreateFile(_, let underlying):
                return text("error.micFile", underlying.localizedDescription)
            case .invalidInputFormat:
                return text("error.invalidMicFormat")
            case .inputDeviceUnavailable(let uid):
                return text("error.inputDeviceUnavailable", uid)
            case .setInputDeviceFailed(let uid, let status):
                return text("error.setInputDeviceFailed", uid, "\(status)")
            }
        }
        return error.localizedDescription
    }

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
            statusMessage = text("status.noAudioToUpload")
            return
        }
        startUpload(job)
    }

    func confirmUploadDespiteDegradedAudio() {
        guard let job = lastUploadJob else {
            statusMessage = text("status.noAudioToUpload")
            return
        }
        UploadStatusStore.appendLog(folderURL: job.folderURL, "User confirmed upload despite degraded recording acceptance.")
        startUpload(job)
    }

    func uploadExisting(_ entry: RecordingEntry) {
        guard let audio = entry.audioURL else {
            statusMessage = text("status.noAudioToUpload")
            return
        }
        let metadata = UploadStatusStore.readMetadata(folderURL: entry.folderURL)
        let job = FeishuUploadJob(
            audioURL: audio,
            folderURL: entry.folderURL,
            meetingTitle: metadata?.meetingTitle ?? entry.title,
            titleSource: metadata?.titleSource.flatMap(RecordingTitleSource.init(rawValue:)),
            calendarEventTitle: metadata?.calendarEventTitle,
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
        statusMessage = text("status.uploadingFeishu")

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
                    self.statusMessage = self.text("status.uploadedFeishu")
                    if shouldCopy {
                        self.copyMinuteURL(result.minuteURL)
                    }
                    if shouldOpen {
                        NSWorkspace.shared.open(result.minuteURL)
                    }
                    self.runLocalCleanup(showStatus: false)
                    self.refreshRecordings()
                }
            } catch {
                let message = RecorderModel.describeUploadError(error)
                UploadStatusStore.markFailed(job: job, error: error)
                await MainActor.run {
                    guard let self else { return }
                    self.uploadState = .failed(message)
                    self.statusMessage = self.text("status.uploadFailed")
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
        statusMessage = text("status.minuteCopied")
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
        statusMessage = text("status.fileCopied", url.lastPathComponent)
    }

    /// Put a text file's contents on the clipboard.
    func copyTextOfFile(_ url: URL) {
        guard let fileText = try? String(contentsOf: url, encoding: .utf8) else {
            statusMessage = text("status.fileReadFailed", url.lastPathComponent)
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(fileText, forType: .string)
        statusMessage = text("status.textCopied", url.lastPathComponent)
    }

    /// Reveal an arbitrary file/folder in Finder.
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Open ~/Documents/Recorder1 in Finder (creating it if needed).
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

    private static func captureIntegrity(for report: AudioQualityReport) -> CaptureIntegrity {
        let leftSilent = report.leftDesktopRMSDB < -80 && report.leftDesktopPeakDB < -60
        let micActive = report.rightMicRMSDB > -80 || report.rightMicPeakDB > -60
        if leftSilent && micActive {
            return .degraded(issues: [
                "Only microphone channel looks active; desktop/system channel is silent."
            ])
        }
        return .passed()
    }
}
