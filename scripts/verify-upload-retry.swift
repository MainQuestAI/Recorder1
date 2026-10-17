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

        let result = try await uploader.upload(job: job)
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
                         "fail-minute-auth-once", "fail-minute-network-once", "fail-notes-once", "not-ready-once",
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
            var failed = false
            do { _ = try await fast.upload(job: scenarioJob) }
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
                _ = try await fast.upload(job: scenarioJob)
                try require(try calls("drive +upload") == 1, "resume duplicated an existing file")
                try require(try calls("drive metas") == 2, "resume did not validate the file")
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
                try require(UploadStatusStore.readMetadata(folderURL: destination)?.uploadStage == "notes_pending", "notes failure checkpoint missing")
                _ = try await fast.upload(job: scenarioJob)
                try require(try calls("drive +upload") == 1 && calls("minutes +upload") == 1, "notes retry duplicated creation")
                try require(try calls("minutes minutes") == 1, "existing minute was not validated")
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
    }
}
