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

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ProbeError.failed(message) }
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

        let folderURL = URL(fileURLWithPath: args[1], isDirectory: true)
        let fakeCLIPath = args[2]
        let fm = FileManager.default
        try fm.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let audioURL = folderURL.appendingPathComponent("audio.m4a")
        let originalAudio = Data("recorder1-upload-retry-probe".utf8)
        try originalAudio.write(to: audioURL, options: .atomic)

        let startedAt = Date(timeIntervalSince1970: 1_781_622_000)
        let endedAt = startedAt.addingTimeInterval(60)
        let job = FeishuUploadJob(
            audioURL: audioURL,
            folderURL: folderURL,
            meetingTitle: "Retry Upload Probe",
            attendees: ["Local Tester"],
            startedAt: startedAt,
            endedAt: endedAt
        )
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

        let logURL = folderURL.appendingPathComponent("upload.log")
        try requireFile(logURL, "upload.log missing after failed upload")
        let failedLog = try String(contentsOf: logURL, encoding: .utf8)
        try require(failedLog.contains("Upload failed"), "upload.log did not record the failure")

        let result = try await uploader.upload(job: job)
        try require(result.fileToken == "fake-file-token", "retry did not return fake file token")
        try require(result.minuteToken == "fake-minute-token", "retry did not return fake minute token")
        let audioAfterRetry = try Data(contentsOf: audioURL)
        try require(audioAfterRetry == originalAudio, "audio.m4a changed after retry")

        guard let uploadedMetadata = UploadStatusStore.readMetadata(folderURL: folderURL) else {
            throw ProbeError.failed("metadata.json missing after retry")
        }
        try require(uploadedMetadata.uploadStatus == "uploaded", "metadata status after retry was \(uploadedMetadata.uploadStatus)")
        try require(uploadedMetadata.fileToken == "fake-file-token", "metadata file_token missing after retry")
        try require(uploadedMetadata.minuteToken == "fake-minute-token", "metadata minute_token missing after retry")
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
        let driveCalls = invocations
            .split(separator: "\n")
            .filter { $0.contains("drive +upload") && $0.contains("--file audio.m4a") }
        try require(driveCalls.count == 2, "expected two drive uploads using relative audio.m4a, saw \(driveCalls.count)")
    }
}
