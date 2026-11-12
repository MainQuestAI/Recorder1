import Darwin
import Foundation

enum ProbeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw ProbeError.failed(message) }
}

func requireFile(_ url: URL, _ message: String) throws {
    try require(FileManager.default.fileExists(atPath: url.path), message)
}

@main
struct UploadRetryProbe {
    static func main() async {
        do {
            try await run()
            print("PASS failed upload preserves audio.m4a and retry succeeds")
        } catch {
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    private static func run() async throws {
        let args = CommandLine.arguments
        try require(args.count == 3, "usage: verify-upload-retry <work-folder> <fake-lark-cli>")

        let cliEnvironment = CLIProcessRunner.processEnvironment()
        try require(
            cliEnvironment["LARK_CLI_NO_PROXY"] == "1",
            "lark-cli proxy bypass was not enabled"
        )

        let folderURL = URL(fileURLWithPath: args[1], isDirectory: true)
        let fakeCLIPath = args[2]
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let audioURL = folderURL.appendingPathComponent("audio.m4a")
        let originalAudio = Data("recorder1-upload-retry-probe".utf8)
        try originalAudio.write(to: audioURL, options: .atomic)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let startedAt = calendar.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: 17,
            hour: 15,
            minute: 0
        ))!
        let endedAt = startedAt.addingTimeInterval(60)
        let job = FeishuUploadJob(
            audioURL: audioURL,
            folderURL: folderURL,
            meetingTitle: "Retry Upload Probe",
            titleSource: .manual,
            calendarEventTitle: nil,
            attendees: ["Local Tester"],
            startedAt: startedAt,
            endedAt: endedAt
        )
        let expectedUploadFileName = "2026-06-17_1500-Retry-Upload-Probe.m4a"
        try require(job.uploadFileName == expectedUploadFileName, "unexpected upload file name: \(job.uploadFileName)")
        UploadStatusStore.markSaved(job: job)

        try "1".write(
            to: folderURL.appendingPathComponent("fail-drive-once"),
            atomically: true,
            encoding: .utf8
        )

        let uploader = FeishuCLIUploader(cliPath: fakeCLIPath, fetchNotes: true)
        var sawExpectedFailure = false
        do {
            _ = try await uploader.upload(job: job)
        } catch {
            sawExpectedFailure = true
            UploadStatusStore.markFailed(job: job, error: error)
        }

        try require(sawExpectedFailure, "first upload unexpectedly succeeded")
        let audioAfterFailure = try Data(contentsOf: audioURL)
        try require(audioAfterFailure == originalAudio, "audio.m4a changed after failed upload")

        guard let failedMetadata = UploadStatusStore.readMetadata(folderURL: folderURL) else {
            throw ProbeError.failed("metadata.json missing after failed upload")
        }
        try require(failedMetadata.uploadStatus == "failed", "metadata status after failure was \(failedMetadata.uploadStatus)")
        try require(failedMetadata.audioPath == audioURL.path, "metadata audio_path did not preserve audio.m4a")
        try require(failedMetadata.titleSource == "manual", "metadata title_source missing after failure")
        try require(failedMetadata.uploadFileName == expectedUploadFileName, "metadata upload_file_name missing after failure")

        let logURL = folderURL.appendingPathComponent("upload.log")
        try requireFile(logURL, "upload.log missing after failed upload")
        let failedLog = try String(contentsOf: logURL, encoding: .utf8)
        try require(failedLog.contains("Upload failed"), "upload.log did not record the failure")

        var phases: [UploadPhase] = []
        let result = try await uploader.upload(job: job) { phases.append($0) }
        try require(phases == [.uploadingAudio, .creatingMinute, .fetchingNotes, .savingResult],
                    "a fresh upload did not report the steps it ran")
        try require(result.fileToken == "fake-file-token", "retry did not return fake file token")
        try require(result.minuteToken == "fake-minute-token", "retry did not return fake minute token")
        let audioAfterRetry = try Data(contentsOf: audioURL)
        try require(audioAfterRetry == originalAudio, "audio.m4a changed after retry")
        let uploadCopyURL = folderURL.appendingPathComponent(job.uploadFileName)
        try requireFile(uploadCopyURL, "named upload copy missing after retry")
        let uploadCopy = try Data(contentsOf: uploadCopyURL)
        try require(uploadCopy == originalAudio, "named upload copy does not match audio.m4a")

        guard let uploadedMetadata = UploadStatusStore.readMetadata(folderURL: folderURL) else {
            throw ProbeError.failed("metadata.json missing after retry")
        }
        try require(uploadedMetadata.uploadStatus == "uploaded", "metadata status after retry was \(uploadedMetadata.uploadStatus)")
        try require(uploadedMetadata.fileToken == "fake-file-token", "metadata file_token missing after retry")
        try require(uploadedMetadata.minuteToken == "fake-minute-token", "metadata minute_token missing after retry")
        try require(uploadedMetadata.titleSource == "manual", "metadata title_source missing after retry")
        try require(uploadedMetadata.uploadFileName == expectedUploadFileName, "metadata upload_file_name missing after retry")
        try require(
            uploadedMetadata.minuteURL == "https://example.feishu.cn/minutes/fake-minute-token",
            "metadata minute_url missing after retry"
        )

        try requireFile(folderURL.appendingPathComponent("feishu_minutes.json"), "feishu_minutes.json missing after retry")
        try requireFile(folderURL.appendingPathComponent("transcript.md"), "transcript.md missing after retry")

        let invocations = try String(
            contentsOf: folderURL.appendingPathComponent("fake-lark-invocations.log"),
            encoding: .utf8
        )
        let expectedUploadArg = "--file \(expectedUploadFileName)"
        let driveCalls = invocations
            .split(separator: "\n")
            .filter { $0.contains("drive +upload") && $0.contains(expectedUploadArg) }
        try require(driveCalls.count == 2, "expected two drive uploads using \(job.uploadFileName), saw \(driveCalls.count)")

        for scenario in ["fail-drive-network-once", "always-drive-network", "fail-minute-service-once",
                         "fail-minute-auth-once", "fail-minute-network-once", "fail-notes-once", "not-ready-once", "skip-notes",
                         "crash-drive-after-create", "crash-minute-after-create"] {
            let destination = folderURL.appendingPathComponent(scenario)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let audio = destination.appendingPathComponent("audio.m4a")
            try originalAudio.write(to: audio)
            let scenarioJob = FeishuUploadJob(audioURL: audio, folderURL: destination,
                meetingTitle: "Probe", titleSource: .manual, calendarEventTitle: nil, attendees: [], startedAt: startedAt, endedAt: endedAt)
            UploadStatusStore.markSaved(job: scenarioJob)
            try Data().write(to: destination.appendingPathComponent(scenario))
            var fast = uploader
            fast.retryDelayNanoseconds = 0
            fast.notesDelayNanoseconds = 0
            fast.fetchNotes = scenario != "skip-notes"
            var scenarioPhases: [UploadPhase] = []
            var scenarioResult: FeishuUploadResult?
            var failed = false
            do { scenarioResult = try await fast.upload(job: scenarioJob) { scenarioPhases.append($0) } }
            catch { failed = true; UploadStatusStore.markFailed(job: scenarioJob, error: error) }
            let shouldFail = ["always-drive-network", "fail-minute-auth-once", "fail-minute-network-once",
                              "crash-drive-after-create", "crash-minute-after-create"].contains(scenario)
            try require(failed == shouldFail, "unexpected failure outcome for \(scenario)")
            func calls(_ command: String) throws -> Int {
                try String(contentsOf: destination.appendingPathComponent("fake-lark-invocations.log"), encoding: .utf8)
                    .split(separator: "\n").filter { $0.contains(":: \(command)") }.count
            }
            if scenario == "fail-drive-network-once" { try require(try calls("drive +upload") == 2, "EOF was not retried") }
            if scenario == "always-drive-network" { try require(try calls("drive +upload") == 3, "retry budget was not bounded") }
            if scenario == "fail-minute-service-once" {
                try require(try calls("drive +upload") == 1, "minute retry duplicated Drive upload")
                try require(try calls("minutes +upload") == 2, "2091006 was not retried")
            }
            if scenario == "fail-minute-auth-once" {
                try require(try calls("minutes +upload") == 1, "authorization error was automatically retried")
                try Data().write(to: destination.appendingPathComponent("missing-file"))
                do { _ = try await fast.upload(job: scenarioJob); throw ProbeError.failed("inaccessible file was reused") }
                catch let error as ProbeError { throw error }
                catch { }
                try require(try calls("minutes +upload") == 1 && calls("drive +upload") == 1,
                            "inaccessible checkpoint caused a new cloud object")
                try fm.removeItem(at: destination.appendingPathComponent("missing-file"))
                scenarioPhases.removeAll()
                _ = try await fast.upload(job: scenarioJob) { scenarioPhases.append($0) }
                try require(try calls("drive +upload") == 1, "resume duplicated an existing file")
                try require(try calls("drive metas") == 2, "resume did not validate the file")
                try require(scenarioPhases == [.checkingExisting, .creatingMinute, .fetchingNotes, .savingResult],
                            "resuming a saved Drive file reported uploading audio")
            }
            if scenario == "fail-minute-network-once" {
                do { _ = try await fast.upload(job: scenarioJob); throw ProbeError.failed("ambiguous creation was replayed") }
                catch let error as ProbeError { throw error }
                catch { }
                try require(try calls("minutes +upload") == 1, "uncertain create request was repeated")
            }
            if scenario.hasPrefix("crash-") {
                let drive = scenario == "crash-drive-after-create"
                let command = drive ? "drive +upload" : "minutes +upload"
                try requireFile(destination.appendingPathComponent(drive ? "remote-drive-created" : "remote-minute-created"),
                                "crash fixture did not simulate remote creation")
                try require(UploadStatusStore.readMetadata(folderURL: destination)?.uploadStage == (drive ? "drive_result_unknown" : "minute_result_unknown"),
                            "CLI crash was not saved as an unknown creation result")
                do { _ = try await fast.upload(job: scenarioJob); throw ProbeError.failed("crashed creation was replayed") }
                catch let error as ProbeError { throw error }
                catch { }
                try require(try calls(command) == 1, "retry duplicated a remotely created artifact after a CLI crash")
            }
            if scenario == "fail-notes-once" {
                try require(scenarioResult?.notesFetchError != nil && scenarioResult?.minuteURL == result.minuteURL,
                            "unavailable notes must still return a usable minute")
                try require(UploadStatusStore.readMetadata(folderURL: destination)?.uploadStage == "notes_pending", "notes failure checkpoint missing")
                func reloadedEntry() -> RecordingEntry? {
                    RecordingsLibrary.recent(limit: 100, rootURL: folderURL)
                        .first { $0.folderURL.lastPathComponent == destination.lastPathComponent }
                }
                let pending = reloadedEntry()
                try require(pending?.notesPending == true && pending?.minuteURL == result.minuteURL,
                            "the recordings library lost the pending notes status or link on reload")
                try Data().write(to: destination.appendingPathComponent("fail-validate-once"))
                scenarioPhases.removeAll()
                do {
                    _ = try await fast.upload(job: scenarioJob) { scenarioPhases.append($0) }
                    throw ProbeError.failed("the fake existing-Minute validation did not fail")
                } catch let error as ProbeError {
                    throw error
                } catch {
                    UploadStatusStore.markFailed(job: scenarioJob, error: error)
                }
                try require(scenarioPhases == [.checkingExisting], "failed validation proceeded to fetch notes")
                let afterFailedValidation = reloadedEntry()
                try require(afterFailedValidation?.notesPending == true && afterFailedValidation?.minuteURL == result.minuteURL,
                            "failed retry hid the pending notes status or link on reload")

                var skipNotes = fast
                skipNotes.fetchNotes = false
                scenarioPhases.removeAll()
                let skipped = try await skipNotes.upload(job: scenarioJob) { scenarioPhases.append($0) }
                try require(scenarioPhases == [.checkingExisting, .savingResult], "disabled retry reported fetching notes")
                try require(skipped.notesFetchError != nil && reloadedEntry()?.notesPending == true,
                            "retry without fetching notes cleared the previous pending status")

                scenarioPhases.removeAll()
                let retry = try await fast.upload(job: scenarioJob) { scenarioPhases.append($0) }
                try require(try calls("drive +upload") == 1 && calls("minutes +upload") == 1, "notes retry duplicated creation")
                try require(try calls("minutes minutes") == 3, "existing minute was not validated on each retry")
                try require(scenarioPhases == [.checkingExisting, .fetchingNotes, .savingResult],
                            "notes retry reported a new upload or minute creation")
                try require(retry.notesFetchError == nil && UploadStatusStore.readMetadata(folderURL: destination)?.uploadStage == "complete",
                            "successful notes retry did not clear the pending result")
                try require(reloadedEntry()?.notesPending == false, "the recordings library still shows notes pending after retry")
            }
            if scenario == "skip-notes" {
                try require(try calls("vc +notes") == 0, "disabled notes fetch ran the CLI")
                try require(scenarioPhases == [.uploadingAudio, .creatingMinute, .savingResult],
                            "disabled notes fetch was shown as an active phase")
                try require(scenarioResult?.notesFetchError == nil && UploadStatusStore.readMetadata(folderURL: destination)?.uploadStage == "complete",
                            "disabled notes fetch was treated as a failure")
            }
            if !shouldFail {
                try Data("modified audio".utf8).write(to: audio)
                do { _ = try await fast.upload(job: scenarioJob); throw ProbeError.failed("changed audio reused a checkpoint") }
                catch let error as ProbeError { throw error }
                catch { }
            }
            print("PASS \(scenario)")
        }
        let corruptFolder = folderURL.appendingPathComponent("corrupt-metadata")
        try fm.createDirectory(at: corruptFolder, withIntermediateDirectories: true)
        let corruptAudio = corruptFolder.appendingPathComponent("audio.m4a")
        try originalAudio.write(to: corruptAudio)
        let corruptURL = corruptFolder.appendingPathComponent("metadata.json")
        let corruptData = Data("{\"file_token\":\"previously-uploaded-file\",\"truncated\":".utf8)
        try corruptData.write(to: corruptURL)
        let corruptJob = FeishuUploadJob(audioURL: corruptAudio, folderURL: corruptFolder, meetingTitle: "Probe",
            attendees: [], startedAt: startedAt, endedAt: endedAt)
        // These are the writes the recording-library acceptance path performs before upload.
        UploadStatusStore.markAudioQuality(folderURL: corruptFolder, report: AudioQualityReport(
            durationSeconds: 60, sampleRate: 48_000, channelCount: 2,
            leftDesktopRMSDB: -20, rightMicRMSDB: -20, leftDesktopPeakDB: -10, rightMicPeakDB: -10, warnings: []))
        UploadStatusStore.markCaptureIntegrity(folderURL: corruptFolder, integrity: .passed())
        try require(try Data(contentsOf: corruptURL) == corruptData, "acceptance overwrote unreadable upload metadata")
        do { try UploadStatusStore.checkpoint(folderURL: corruptFolder, stage: "preparing"); throw ProbeError.failed("corrupt checkpoint accepted") }
        catch let error as ProbeError { throw error }
        catch { }
        do { _ = try await uploader.upload(job: corruptJob); throw ProbeError.failed("corrupt metadata allowed upload") }
        catch let error as ProbeError { throw error }
        catch { UploadStatusStore.markFailed(job: corruptJob, error: error) }
        try require(try Data(contentsOf: corruptURL) == corruptData, "failure handler overwrote unreadable upload metadata")
        try require(!fm.fileExists(atPath: corruptFolder.appendingPathComponent("fake-lark-invocations.log").path),
                    "corrupt upload metadata reached the CLI")
        print("PASS corrupt metadata survives acceptance and blocks upload before CLI execution")
        let executable = CLIExecutable(url: URL(fileURLWithPath: fakeCLIPath), prefixArguments: [])
        do {
            _ = try await CLIProcessRunner(timeoutSeconds: 0.3).run(executable: executable, arguments: ["probe", "sleep"], workingDirectory: folderURL)
            throw ProbeError.failed("timeout did not stop CLI")
        } catch CLIProcessError.timedOut { }
        let pid = Int32(try String(contentsOf: folderURL.appendingPathComponent("sleep.pid"), encoding: .utf8))!
        try require(kill(pid, 0) == -1 && errno == ESRCH, "timed-out CLI is still running")
        print("PASS timed-out native CLI is terminated")
        try verifyOverlappingPresentation(first: job, minuteURL: result.minuteURL)
    }

    private static func verifyOverlappingPresentation(first: FeishuUploadJob, minuteURL: URL) throws {
        let secondFolder = first.folderURL.appendingPathComponent("other")
        let second = FeishuUploadJob(audioURL: secondFolder.appendingPathComponent("audio.m4a"), folderURL: secondFolder,
                                    meetingTitle: "Second recording", attendees: [], startedAt: first.startedAt, endedAt: first.endedAt)
        let secondURL = minuteURL.appendingPathComponent("second")
        var presentation = UploadPresentation()
        try require(presentation.begin(first), "first upload did not start")
        presentation.update(.fetchingNotes, for: first)
        try require(!presentation.begin(first), "same recording was admitted twice")
        try require(presentation.begin(second), "another recording could not upload concurrently")
        presentation.update(.uploadingAudio, for: second)
        presentation.update(.savingResult, for: first)
        try require(presentation.current?.job == second && presentation.current?.phase == .uploadingAudio,
                    "an older callback took over the current progress")
        try require(presentation.finish(second, with: .uploaded(secondURL, notesPending: true)),
                    "newest upload did not own its result actions")
        try require(presentation.current?.job == first && presentation.current?.phase == .savingResult,
                    "ongoing upload did not return after the newest upload completed")
        try require(presentation.isActive(first.folderURL) && !presentation.isActive(second.folderURL),
                    "another recording's upload disabled the completed recording's retry")
        let thirdFolder = first.folderURL.appendingPathComponent("unrelated")
        try require(!presentation.isActive(thirdFolder), "another recording's upload disabled an unrelated recording")
        try require(presentation.finish(first, with: .uploaded(minuteURL, notesPending: false)),
                    "an older successful upload was not allowed to run its automatic link actions")
        try require(presentation.current == nil && presentation.selectedJob == second
                    && presentation.result == .uploaded(secondURL, notesPending: true),
                    "a late callback changed the partial result or its recording")
        try require(!presentation.finish(first, with: .uploaded(minuteURL, notesPending: false)),
                    "a duplicate completion was allowed to repeat link actions")

        try require(presentation.begin(first), "a finished upload could not restart")
        presentation.requireConfirmation("Check audio", for: second)
        try require(presentation.finish(first, with: .uploaded(minuteURL, notesPending: false)),
                    "a newer confirmation prevented the earlier success from running its link actions")
        try require(presentation.selectedJob == second && presentation.result == .needsConfirmation("Check audio"),
                    "older success replaced a newer confirmation")
        try require(presentation.current == nil && presentation.canConfirm(second),
                    "the correct confirmation was unavailable without an active upload")
        presentation.requireConfirmation("Check another recording", for: first)
        try require(!presentation.canConfirm(second) && presentation.canConfirm(first),
                    "a stale confirmation button could approve a different recording")
        try require(presentation.begin(first) && !presentation.canConfirm(first),
                    "a confirmation remained valid after its recording began uploading")
        print("PASS concurrent upload controls, automatic link actions, and recording-specific confirmation")
    }
}
