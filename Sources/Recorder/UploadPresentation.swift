import Foundation

enum UploadPhase: String, Sendable {
    case preparing
    case checkingExisting
    case uploadingAudio
    case creatingMinute
    case fetchingNotes
    case savingResult
}

/// Orders in-flight uploads by start time and keeps the panel's actions bound to
/// one recording. Recording controls do not own or reset this state.
struct UploadPresentation {
    struct Progress {
        let job: FeishuUploadJob
        var phase: UploadPhase = .preparing
    }

    private var active: [Progress] = []
    private(set) var selectedJob: FeishuUploadJob?
    private(set) var result: UploadState = .idle

    var current: Progress? { active.last }

    func isActive(_ folderURL: URL) -> Bool {
        active.contains { $0.job.folderURL == folderURL }
    }

    mutating func begin(_ job: FeishuUploadJob) -> Bool {
        guard !isActive(job.folderURL) else { return false }
        active.append(Progress(job: job))
        selectedJob = job
        result = .idle
        return true
    }

    mutating func update(_ phase: UploadPhase, for job: FeishuUploadJob) {
        guard let index = active.firstIndex(where: { $0.job.folderURL == job.folderURL }) else { return }
        active[index].phase = phase
    }

    mutating func requireConfirmation(_ message: String, for job: FeishuUploadJob) {
        selectedJob = job
        result = .needsConfirmation(message)
    }

    func canConfirm(_ job: FeishuUploadJob) -> Bool {
        guard case .needsConfirmation = result else { return false }
        return selectedJob == job
    }

    /// Returns whether an active upload was completed, independently of panel selection.
    @discardableResult
    mutating func finish(_ job: FeishuUploadJob, with state: UploadState) -> Bool {
        guard let index = active.firstIndex(where: { $0.job.folderURL == job.folderURL }) else { return false }
        active.remove(at: index)
        if selectedJob?.folderURL == job.folderURL {
            result = state
        }
        return true
    }
}
