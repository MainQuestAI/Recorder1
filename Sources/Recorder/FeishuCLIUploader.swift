import Foundation

struct FeishuCLIUploader {
    var cliPath: String
    var fetchNotes: Bool
    var runner = CLIProcessRunner()

    func upload(job: FeishuUploadJob) async throws -> FeishuUploadResult {
        let executable = try CLIProcessRunner.resolveLarkCLI(configuredPath: cliPath)
        let uploadAudioURL = try job.prepareAudioForUpload()
        UploadStatusStore.markUploading(job: job)
        UploadStatusStore.appendLog(folderURL: job.folderURL, "Prepared upload file: \(uploadAudioURL.lastPathComponent)")

        let driveResult = try await runLogged(
            executable: executable,
            arguments: ["drive", "+upload", "--as", "user", "--file", uploadAudioURL.lastPathComponent, "--json"],
            job: job,
            label: "drive +upload"
        )
        let driveJSON = try FeishuMinutesParser.parseJSON(from: driveResult.stdout)
        let fileToken = try FeishuMinutesParser.extractFileToken(from: driveJSON)
        UploadStatusStore.markFileUploaded(folderURL: job.folderURL, fileToken: fileToken)

        let minutesResult = try await runLogged(
            executable: executable,
            arguments: ["minutes", "+upload", "--as", "user", "--file-token", fileToken, "--json"],
            job: job,
            label: "minutes +upload"
        )
        let minutesJSON = try FeishuMinutesParser.parseJSON(from: minutesResult.stdout)
        let minuteURL = try FeishuMinutesParser.extractMinuteURL(from: minutesJSON)
        let minuteToken = try FeishuMinutesParser.minuteToken(from: minuteURL)
        UploadStatusStore.markMinuteCreated(folderURL: job.folderURL, minuteURL: minuteURL, minuteToken: minuteToken)

        var notesJSON: Any?
        var notesFetchError: String?
        if fetchNotes {
            do {
                notesJSON = try await fetchNotesWhenReady(
                    executable: executable,
                    minuteToken: minuteToken,
                    job: job
                )
                if let notesJSON, FeishuMinutesParser.containsMinuteNotReady(notesJSON) {
                    notesFetchError = "minute not ready after waiting"
                }
            } catch {
                notesFetchError = describe(error)
                UploadStatusStore.appendLog(folderURL: job.folderURL, "vc +notes failed: \(notesFetchError ?? "")")
            }
        } else {
            UploadStatusStore.appendLog(folderURL: job.folderURL, "vc +notes skipped by settings.")
        }

        let minutesJSONURL = try writeMinutesJSON(
            folderURL: job.folderURL,
            driveJSON: driveJSON,
            minutesJSON: minutesJSON,
            notesJSON: notesJSON,
            fileToken: fileToken,
            minuteURL: minuteURL,
            minuteToken: minuteToken,
            notesFetchError: notesFetchError
        )

        let transcriptURL = try writeTranscriptIfPresent(notesJSON, folderURL: job.folderURL)
        let summaryURL = try writeSummaryIfPresent(notesJSON, folderURL: job.folderURL)

        let result = FeishuUploadResult(
            fileToken: fileToken,
            minuteURL: minuteURL,
            minuteToken: minuteToken,
            minutesJSONURL: minutesJSONURL,
            transcriptURL: transcriptURL,
            summaryURL: summaryURL,
            notesFetchError: notesFetchError
        )
        UploadStatusStore.markUploaded(result: result, folderURL: job.folderURL)
        return result
    }

    private func fetchNotesWhenReady(
        executable: CLIExecutable,
        minuteToken: String,
        job: FeishuUploadJob
    ) async throws -> Any {
        let maxAttempts = 12
        let delayNanoseconds: UInt64 = 15_000_000_000
        var lastJSON: Any?

        for attempt in 1...maxAttempts {
            let notesResult = try await runLogged(
                executable: executable,
                arguments: [
                    "vc", "+notes",
                    "--as", "user",
                    "--minute-tokens", minuteToken,
                    "--overwrite",
                    "--json",
                ],
                job: job,
                label: "vc +notes attempt \(attempt)/\(maxAttempts)"
            )
            let json = try FeishuMinutesParser.parseJSON(from: notesResult.stdout)
            lastJSON = json

            if !FeishuMinutesParser.containsMinuteNotReady(json) {
                return json
            }

            if attempt < maxAttempts {
                UploadStatusStore.appendLog(folderURL: job.folderURL, "Feishu minute not ready; waiting 15s before retry.")
                try await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        return lastJSON ?? ["error": "minute not ready after waiting"]
    }

    private func runLogged(
        executable: CLIExecutable,
        arguments: [String],
        job: FeishuUploadJob,
        label: String
    ) async throws -> CLIProcessResult {
        UploadStatusStore.appendLog(folderURL: job.folderURL, "Running \(label): \(([executable.url.path] + executable.prefixArguments + arguments).joined(separator: " "))")
        do {
            let result = try await runner.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: job.folderURL
            )
            UploadStatusStore.appendLog(folderURL: job.folderURL, "\(label) exit=\(result.exitCode)")
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stdout.isEmpty {
                UploadStatusStore.appendLog(folderURL: job.folderURL, "\(label) stdout: \(snippet(stdout))")
            }
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stderr.isEmpty {
                UploadStatusStore.appendLog(folderURL: job.folderURL, "\(label) stderr: \(snippet(stderr))")
            }
            return result
        } catch {
            UploadStatusStore.appendLog(folderURL: job.folderURL, "\(label) error: \(describe(error))")
            throw error
        }
    }

    private func writeMinutesJSON(
        folderURL: URL,
        driveJSON: Any,
        minutesJSON: Any,
        notesJSON: Any?,
        fileToken: String,
        minuteURL: URL,
        minuteToken: String,
        notesFetchError: String?
    ) throws -> URL {
        var combined: [String: Any] = [
            "file_token": fileToken,
            "minute_url": minuteURL.absoluteString,
            "minute_token": minuteToken,
            "drive": driveJSON,
            "minutes": minutesJSON,
        ]
        if let notesJSON {
            combined["notes"] = notesJSON
        }
        if let notesFetchError {
            combined["notes_fetch_error"] = notesFetchError
        }

        let data = try FeishuMinutesParser.prettyJSONData(combined)
        let url = folderURL.appendingPathComponent("feishu_minutes.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func writeTranscriptIfPresent(_ notesJSON: Any?, folderURL: URL) throws -> URL? {
        guard let notesJSON,
              let markdown = FeishuMinutesParser.extractTranscriptMarkdown(from: notesJSON, folderURL: folderURL) else {
            return nil
        }
        let url = folderURL.appendingPathComponent("transcript.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeSummaryIfPresent(_ notesJSON: Any?, folderURL: URL) throws -> URL? {
        guard let notesJSON,
              let markdown = FeishuMinutesParser.extractSummaryMarkdown(from: notesJSON) else {
            return nil
        }
        let url = folderURL.appendingPathComponent("summary.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func snippet(_ raw: String) -> String {
        raw.count > 4000 ? String(raw.prefix(4000)) + "...[truncated]" : raw
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return error.localizedDescription
    }
}
