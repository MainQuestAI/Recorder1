import Foundation

// Explicitly opt in: this creates a private Drive file and a Minute using the local user session.
@main
struct LiveUploadProbe {
    static func main() async {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--live-upload" else {
            fputs("usage: live-upload-probe --live-upload <folder-containing-audio.m4a>\n", stderr)
            exit(2)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let job = FeishuUploadJob(audioURL: folder.appendingPathComponent("audio.m4a"), folderURL: folder,
            meetingTitle: "Recorder1 分片上传验证", titleSource: .manual, calendarEventTitle: nil, attendees: [],
            startedAt: Date(), endedAt: Date())
        do {
            let uploader = FeishuCLIUploader(cliPath: "", fetchNotes: true)
            let first = try await uploader.upload(job: job)
            let second = try await uploader.upload(job: job)
            guard first.fileToken == second.fileToken, first.minuteToken == second.minuteToken else {
                throw FeishuUploadError.checkpoint("Retry created a duplicate artifact")
            }
            let report: [String: Any] = ["ok": true, "same_file_after_retry": true, "same_minute_after_retry": true,
                "minute_url": second.minuteURL.absoluteString, "notes_error": second.notesFetchError as Any? ?? NSNull(),
                "transcript_present": second.transcriptURL != nil]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("live-result.json"), options: .atomic)
            print(String(decoding: data, as: UTF8.self))
        } catch {
            UploadStatusStore.markFailed(job: job, error: error)
            fputs("FAIL \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
