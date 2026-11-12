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

    mutating func begin(_ job: FeishuUploadJob) -> Bool {
        guard !active.contains(where: { $0.job.folderURL == job.folderURL }) else { return false }
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

    /// Returns whether this result owns the panel and its automatic link actions.
    @discardableResult
    mutating func finish(_ job: FeishuUploadJob, with state: UploadState) -> Bool {
        guard let index = active.firstIndex(where: { $0.job.folderURL == job.folderURL }) else { return false }
        active.remove(at: index)
        guard selectedJob?.folderURL == job.folderURL else { return false }
        result = state
        return true
    }
}
