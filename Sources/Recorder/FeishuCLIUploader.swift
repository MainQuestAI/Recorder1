import Foundation

enum FeishuUploadError: LocalizedError {
    case checkpoint(String)
    case stage(String, String)
    var errorDescription: String? {
        switch self {
        case .checkpoint(let message): return message
        case .stage(let stage, let message): return "\(stage)：\(message)"
        }
    }
}

struct FeishuCLIUploader {
    var cliPath: String
    var fetchNotes: Bool
    var runner = CLIProcessRunner()
    var retryDelayNanoseconds: UInt64 = 2_000_000_000
    var notesDelayNanoseconds: UInt64 = 15_000_000_000

    func upload(job: FeishuUploadJob) async throws -> FeishuUploadResult {
        let executable = try CLIProcessRunner.resolveLarkCLI(configuredPath: cliPath)
        let saved = UploadStatusStore.readMetadata(folderURL: job.folderURL)
        if FileManager.default.fileExists(atPath: job.folderURL.appendingPathComponent("metadata.json").path), saved == nil {
            throw FeishuUploadError.checkpoint("上传记录无法读取，请保留 metadata.json 并检查后重试。")
        }
        let fingerprint = try job.audioFingerprint()
        if let original = saved?.uploadAudioSHA256, original != fingerprint {
            throw FeishuUploadError.checkpoint("本地音频已变化，不能复用原上传记录。请保留原录音并检查云端文件。")
        }
        let stage = saved?.uploadStage ?? ""
        if (["uploading_drive", "drive_result_unknown"].contains(stage) && saved?.fileToken == nil)
            || (["creating_minute", "minute_result_unknown"].contains(stage) && saved?.minuteToken == nil) {
            throw FeishuUploadError.checkpoint("上次创建请求的结果尚未确认，请先检查飞书云空间或妙记，避免重复创建。详细信息见 upload.log。")
        }
        let uploadAudioURL = try job.prepareAudioForUpload()
        UploadStatusStore.markUploading(job: job)
        try UploadStatusStore.checkpoint(folderURL: job.folderURL, stage: "preparing", fingerprint: fingerprint)
        UploadStatusStore.appendLog(folderURL: job.folderURL, "Prepared upload file: \(uploadAudioURL.lastPathComponent)")

        let driveJSON: Any
        let fileToken: String
        let minutesJSON: Any
        let minuteURL: URL
        let minuteToken: String
        if let token = saved?.minuteToken, let urlString = saved?.minuteURL, let url = URL(string: urlString),
           let file = saved?.fileToken {
            _ = try await runLogged(executable: executable,
                arguments: ["minutes", "minutes", "get", "--as", "user", "--minute-token", token, "--json"],
                job: job, label: "validate existing minute")
            fileToken = file
            minuteToken = token
            minuteURL = url
            driveJSON = ["file_token": file, "resumed": true]
            minutesJSON = ["minute_url": urlString, "resumed": true]
            UploadStatusStore.appendLog(folderURL: job.folderURL, "Resuming existing minute; no Drive or Minutes creation.")
        } else {
            if let token = saved?.fileToken {
                let request = try JSONSerialization.data(withJSONObject: ["request_docs": [["doc_token": token, "doc_type": "file"]]])
                let result = try await runLogged(executable: executable,
                    arguments: ["drive", "metas", "batch_query", "--as", "user", "--data", String(decoding: request, as: UTF8.self), "--json"],
                    job: job, label: "validate existing file")
                let json = try FeishuMinutesParser.parseJSON(from: result.stdout) as? [String: Any]
                let data = json?["data"] as? [String: Any]
                let metas = data?["metas"] as? [[String: Any]] ?? []
                guard metas.contains(where: { $0["doc_token"] as? String == token }) else {
                    throw FeishuUploadError.checkpoint("已上传文件暂不可访问；保留上传记录，请检查飞书文件权限或文件是否被删除。")
                }
                fileToken = token
                driveJSON = ["file_token": token, "resumed": true]
                UploadStatusStore.appendLog(folderURL: job.folderURL, "Resuming uploaded Drive file; skipping drive +upload.")
            } else {
                try UploadStatusStore.checkpoint(folderURL: job.folderURL, stage: "uploading_drive")
                let driveResult = try await runLogged(
                    executable: executable,
                    arguments: ["drive", "+upload", "--as", "user", "--file", uploadAudioURL.lastPathComponent, "--json"],
                    job: job,
                    label: "drive +upload"
                )
                driveJSON = try FeishuMinutesParser.parseJSON(from: driveResult.stdout)
                fileToken = try FeishuMinutesParser.extractFileToken(from: driveJSON)
                try UploadStatusStore.checkpoint(folderURL: job.folderURL, stage: "file_uploaded", fileToken: fileToken)
                UploadStatusStore.markFileUploaded(folderURL: job.folderURL, fileToken: fileToken)
            }

            try UploadStatusStore.checkpoint(folderURL: job.folderURL, stage: "creating_minute")
            let minutesResult = try await runLogged(
                executable: executable,
                arguments: ["minutes", "+upload", "--as", "user", "--file-token", fileToken, "--json"],
                job: job,
                label: "minutes +upload"
            )
            minutesJSON = try FeishuMinutesParser.parseJSON(from: minutesResult.stdout)
            minuteURL = try FeishuMinutesParser.extractMinuteURL(from: minutesJSON)
            minuteToken = try FeishuMinutesParser.minuteToken(from: minuteURL)
            try UploadStatusStore.checkpoint(folderURL: job.folderURL, stage: "minute_created", fileToken: fileToken,
                                             minuteURL: minuteURL, minuteToken: minuteToken)
            UploadStatusStore.markMinuteCreated(folderURL: job.folderURL, minuteURL: minuteURL, minuteToken: minuteToken)
        }
        try UploadStatusStore.checkpoint(folderURL: job.folderURL, stage: "fetching_notes")

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
        try UploadStatusStore.checkpoint(folderURL: job.folderURL, stage: notesFetchError == nil ? "complete" : "notes_pending")
        return result
    }

    private func fetchNotesWhenReady(
        executable: CLIExecutable,
        minuteToken: String,
        job: FeishuUploadJob
    ) async throws -> Any {
        let maxAttempts = 12
        let delayNanoseconds = notesDelayNanoseconds
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
        let drive = arguments.prefix(2).elementsEqual(["drive", "+upload"])
        let minute = arguments.prefix(2).elementsEqual(["minutes", "+upload"])
        let displayStage = drive ? "云空间上传" : minute ? "妙记创建" : label.hasPrefix("vc +notes") ? "逐字稿获取" : "云端记录检查"
        for attempt in 1...3 {
            try Task.checkCancellation()
            if drive || minute {
                try UploadStatusStore.checkpoint(folderURL: job.folderURL, stage: drive ? "uploading_drive" : "creating_minute")
            }
            let started = Date()
            UploadStatusStore.appendLog(folderURL: job.folderURL, "Running \(label) attempt \(attempt)/3: \(([executable.url.path] + executable.prefixArguments + arguments).joined(separator: " "))")
            do {
                var operationRunner = runner
                if !drive { operationRunner.timeoutSeconds = min(30, runner.timeoutSeconds) }
                let result = try await operationRunner.run(executable: executable, arguments: arguments, workingDirectory: job.folderURL)
                // Some CLI versions can return an error envelope with exit 0. Treat it as failure.
                if let json = try? FeishuMinutesParser.parseJSON(from: result.stdout) as? [String: Any], json["ok"] as? Bool == false {
                    throw CLIProcessError.commandFailed(command: result.commandLine, exitCode: 1, stdout: result.stdout, stderr: result.stderr)
                }
                UploadStatusStore.appendLog(folderURL: job.folderURL, "\(label) exit=0 elapsed=\(Int(Date().timeIntervalSince(started)))s")
                if !result.stdout.isEmpty { UploadStatusStore.appendLog(folderURL: job.folderURL, "\(label) stdout: \(snippet(result.stdout))") }
                if !result.stderr.isEmpty { UploadStatusStore.appendLog(folderURL: job.folderURL, "\(label) stderr: \(snippet(result.stderr))") }
                return result
            } catch {
                UploadStatusStore.appendLog(folderURL: job.folderURL, "\(label) elapsed=\(Int(Date().timeIntervalSince(started)))s error: \(describe(error))")
                let cli = error as? CLIProcessError
                let api = cli?.apiError
                let type = api?["type"] as? String
                let code = (api?["code"] as? NSNumber)?.intValue
                let message = api?["message"] as? String ?? ""
                let partialUpload = drive && type == "network" && (message.contains("upload_part") || message.contains("upload_prepare"))
                let explicitRejection = ["api", "authorization", "validation", "rate_limit"].contains(type ?? "")
                let network = type == "network" || { if case .timedOut = cli { return true }; return false }()
                // A crash or truncated/non-JSON response can happen after remote creation.
                // Only an explicit rejection or a known unfinished multipart stage is safe to replay.
                let uncertain = (drive || minute) && !explicitRejection && !partialUpload
                if drive || minute {
                    try UploadStatusStore.checkpoint(folderURL: job.folderURL, stage: uncertain
                        ? (drive ? "drive_result_unknown" : "minute_result_unknown")
                        : (drive ? "drive_failed" : "minute_failed"))
                }
                let transient = partialUpload || (explicitRejection && [2091006, 99991400, 99991401].contains(code ?? 0))
                    || (!(drive || minute) && network)
                if transient && attempt < 3 {
                    UploadStatusStore.appendLog(folderURL: job.folderURL, "Temporary failure; retrying \(label) with backoff, preserving completed stages.")
                    try await Task.sleep(nanoseconds: retryDelayNanoseconds * UInt64(attempt))
                    continue
                }
                let detail = cli?.briefDescription ?? describe(error)
                let suffix = uncertain ? "；创建结果待确认，请检查飞书后再处理，避免重复创建。" : ""
                throw FeishuUploadError.stage(displayStage, detail + suffix)
            }
        }
        throw FeishuUploadError.stage(displayStage, "重试次数已用尽")
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
        let existingURL = folderURL.appendingPathComponent("feishu_minutes.json")
        var combined = (try? Data(contentsOf: existingURL))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let fields: [String: Any] = [
            "file_token": fileToken,
            "minute_url": minuteURL.absoluteString,
            "minute_token": minuteToken,
            "drive": driveJSON,
            "minutes": minutesJSON,
        ]
        for (key, value) in fields {
            if ["drive", "minutes"].contains(key), combined[key] != nil,
               (value as? [String: Any])?["resumed"] as? Bool == true { continue }
            combined[key] = value
        }
        if let notesJSON {
            combined["notes"] = notesJSON
        }
        if let notesFetchError {
            combined["notes_fetch_error"] = notesFetchError
        } else {
            combined.removeValue(forKey: "notes_fetch_error")
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
