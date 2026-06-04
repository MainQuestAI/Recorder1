import Foundation

/// Transcribes an audio file with the Gemini API, mirroring the `/transcribe`
/// skill's `transcribe_gemini.py` recipe:
///
///   1. Upload the file via the resumable **Files API** (`/upload/v1beta/files`).
///   2. Wait until the uploaded file's `state` is `ACTIVE`.
///   3. Call `generateContent` on a Flash model (default `gemini-3-flash-preview`)
///      with `thinkingBudget = 0` (transcription is mechanical; thinking tokens
///      only eat into the output budget) and a diarization/cleanup prompt.
///
/// The model returns Markdown: timestamped `Speaker N` turns plus a trailing
/// `## Speaker identity guesses` section. Speaker *names* are never put in the
/// transcript body — only guessed at the end — which keeps the body auditable.
///
/// This recorder has an advantage the generic skill doesn't: it knows the stereo
/// channel layout (LEFT = desktop/system audio ≈ remote callers, RIGHT = mic ≈
/// local), so the prompt feeds that in to sharpen diarization, alongside the
/// meeting title + invited attendees pulled from Calendar.
///
/// Value type with `async` methods → runs off the main actor when `await`ed.
struct GeminiTranscriber {

    /// Context supplied to the model to improve diarization + identity guesses.
    struct Context {
        var meetingTitle: String?
        var attendees: [String]
        var startedAt: Date?
        /// Who the local microphone (right channel) usually is. nil = don't name
        /// the local speaker (the prompt omits the hint entirely).
        var localSpeakerName: String?

        init(meetingTitle: String? = nil,
             attendees: [String] = [],
             startedAt: Date? = nil,
             localSpeakerName: String? = nil) {
            self.meetingTitle = meetingTitle
            self.attendees = attendees
            self.startedAt = startedAt
            self.localSpeakerName = localSpeakerName
        }
    }

    enum TranscriberError: LocalizedError {
        case missingUploadURL
        case uploadFailed(status: Int, body: String)
        case processingFailed
        case generateFailed(status: Int, body: String)
        case blocked(String)
        case emptyResponse(finishReason: String?)

        var errorDescription: String? {
            switch self {
            case .missingUploadURL:
                return "Gemini upload did not return an upload URL."
            case .uploadFailed(let status, let body):
                return "Upload failed (HTTP \(status)): \(Self.snippet(body))"
            case .processingFailed:
                return "Gemini could not process the uploaded audio."
            case .generateFailed(let status, let body):
                if status == 429 {
                    return "Gemini rate limit / quota reached (HTTP 429)."
                }
                if status == 400 && body.contains("API key") {
                    return "Gemini rejected the API key (HTTP 400). Check the key in Settings."
                }
                return "Transcription request failed (HTTP \(status)): \(Self.snippet(body))"
            case .blocked(let reason):
                return "Gemini blocked the response: \(reason)."
            case .emptyResponse(let finish):
                if finish == "MAX_TOKENS" {
                    return "Transcript exceeded the output limit (MAX_TOKENS). Try a shorter recording."
                }
                return "Gemini returned an empty transcript\(finish.map { " (\($0))" } ?? "")."
            }
        }

        private static func snippet(_ s: String) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ")
            return one.count > 240 ? String(one.prefix(240)) + "…" : one
        }
    }

    /// Gemini model id. Default is the recommended one-shot Flash model.
    var model: String = "gemini-3-flash-preview"

    /// The diarization / cleanup prompt. Editable from Settings. Two placeholders
    /// are filled in at transcription time from runtime state and may appear
    /// anywhere in the template:
    ///   - `{{CHANNEL_LAYOUT}}` — the stereo left/right channel description
    ///     (the right-channel line names the local speaker when one is set).
    ///   - `{{CONTEXT}}` — meeting title, invited attendees, and the local-speaker
    ///     hint, when available (empty otherwise).
    /// Defaults to ``defaultPromptTemplate``.
    var promptTemplate: String = GeminiTranscriber.defaultPromptTemplate

    private let base = "https://generativelanguage.googleapis.com"

    // MARK: - Public

    /// Upload + transcribe `audioURL`, returning the model's Markdown transcript.
    func transcribe(audioURL: URL, apiKey: String, context: Context) async throws -> String {
        let mime = Self.mime(for: audioURL)
        let uploaded = try await upload(audioURL, apiKey: apiKey, mime: mime)
        let activeURI = try await waitUntilActive(uploaded, apiKey: apiKey)
        let prompt = Self.makePrompt(context: context, template: promptTemplate)
        return try await generate(prompt: prompt, fileURI: activeURI, mime: mime, apiKey: apiKey)
    }

    // MARK: - Files API upload (resumable, single-shot finalize)

    private struct UploadedFile {
        let name: String   // e.g. "files/abc123"
        let uri: String    // fully-qualified file uri used by generateContent
        let state: String  // PROCESSING | ACTIVE | FAILED
    }

    private func upload(_ url: URL, apiKey: String, mime: String) async throws -> UploadedFile {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0

        // 1. Start a resumable session.
        var start = URLRequest(url: URL(string: "\(base)/upload/v1beta/files?key=\(apiKey)")!)
        start.httpMethod = "POST"
        start.timeoutInterval = 60
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mime, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(
            withJSONObject: ["file": ["display_name": url.lastPathComponent]]
        )

        let (startData, startResp) = try await URLSession.shared.data(for: start)
        let startHTTP = startResp as? HTTPURLResponse
        guard let startHTTP, (200..<300).contains(startHTTP.statusCode) else {
            throw TranscriberError.uploadFailed(
                status: (startResp as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(decoding: startData, as: UTF8.self)
            )
        }
        guard let uploadURLString = startHTTP.value(forHTTPHeaderField: "X-Goog-Upload-URL"),
              let uploadURL = URL(string: uploadURLString) else {
            throw TranscriberError.missingUploadURL
        }

        // 2. Upload the bytes and finalize in one request (streamed from disk).
        var finalize = URLRequest(url: uploadURL)
        finalize.httpMethod = "POST"
        finalize.timeoutInterval = 600
        finalize.setValue("0", forHTTPHeaderField: "X-Goog-Upload-Offset")
        finalize.setValue("upload, finalize", forHTTPHeaderField: "X-Goog-Upload-Command")

        let (finData, finResp) = try await URLSession.shared.upload(for: finalize, fromFile: url)
        guard let finHTTP = finResp as? HTTPURLResponse, (200..<300).contains(finHTTP.statusCode) else {
            throw TranscriberError.uploadFailed(
                status: (finResp as? HTTPURLResponse)?.statusCode ?? -1,
                body: String(decoding: finData, as: UTF8.self)
            )
        }

        let obj = try? JSONSerialization.jsonObject(with: finData) as? [String: Any]
        let fileObj = obj?["file"] as? [String: Any]
        guard let uri = fileObj?["uri"] as? String, let name = fileObj?["name"] as? String else {
            throw TranscriberError.uploadFailed(status: finHTTP.statusCode,
                                                body: String(decoding: finData, as: UTF8.self))
        }
        return UploadedFile(name: name, uri: uri, state: (fileObj?["state"] as? String) ?? "PROCESSING")
    }

    /// Poll the file resource until it reports `ACTIVE` (audio needs server-side
    /// processing before it can be referenced). Times out after ~90s and tries the
    /// generate call anyway.
    private func waitUntilActive(_ file: UploadedFile, apiKey: String) async throws -> String {
        if file.state == "ACTIVE" { return file.uri }
        let statusURL = URL(string: "\(base)/v1beta/\(file.name)?key=\(apiKey)")!

        for _ in 0..<90 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let (data, resp) = try? await URLSession.shared.data(from: statusURL),
                  let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            switch obj["state"] as? String {
            case "ACTIVE":
                return (obj["uri"] as? String) ?? file.uri
            case "FAILED":
                throw TranscriberError.processingFailed
            default:
                continue
            }
        }
        return file.uri
    }

    // MARK: - generateContent

    private func generate(prompt: String, fileURI: String, mime: String, apiKey: String) async throws -> String {
        var req = URLRequest(url: URL(string: "\(base)/v1beta/models/\(model):generateContent?key=\(apiKey)")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "contents": [["parts": [
                ["text": prompt],
                ["fileData": ["mimeType": mime, "fileUri": fileURI]],
            ]]],
            "generationConfig": [
                "temperature": 0.2,
                "maxOutputTokens": 65536,
                // Instant mode: any thinking budget eats output tokens and can trip
                // MAX_TOKENS before the transcript finishes on long audio.
                "thinkingConfig": ["thinkingBudget": 0],
            ],
        ])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw TranscriberError.generateFailed(status: -1, body: "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw TranscriberError.generateFailed(status: http.statusCode,
                                                  body: String(decoding: data, as: UTF8.self))
        }

        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let pf = obj?["promptFeedback"] as? [String: Any],
           let reason = pf["blockReason"] as? String {
            throw TranscriberError.blocked(reason)
        }

        let candidate = (obj?["candidates"] as? [[String: Any]])?.first
        let finish = candidate?["finishReason"] as? String
        let parts = (candidate?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let text = (parts ?? [])
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw TranscriberError.emptyResponse(finishReason: finish)
        }
        return text
    }

    // MARK: - Prompt

    /// The built-in transcription prompt. `{{CHANNEL_LAYOUT}}` and `{{CONTEXT}}`
    /// are substituted per-recording by ``makePrompt(context:template:)``. Users
    /// can override the whole thing in Settings; an empty override falls back here.
    static let defaultPromptTemplate = """
    The input is a STEREO audio recording of a meeting or call with multiple participants talking.
    Produce a professionally cleaned-up transcript of the audio.

    {{CHANNEL_LAYOUT}}

    Requirements:
    - Do NOT shift meaning. Remove disfluencies (um, uh, repeats, false starts). Preserve intent and voice.
    - Fix obvious speech-to-text artifacts using audible context.
    - Distinguish speakers by VOICE (timbre, cadence, accent) and by channel (left = remote, right = local). Label them consistently as `Speaker 1`, `Speaker 2`, etc., in order of first appearance. Do NOT put real names in the transcript body, even if names are mentioned in the audio.
    - Format as Markdown.
    - Transcript line format: `[HH:MM:SS] **Speaker N**: paragraph`.
    - Mark unclear audio as `[unclear]`.
    - Transcribe the FULL audio, not a summary.

    At the END of the output, add a section titled `## Speaker identity guesses`. For each `Speaker N`, give your best guess of who they are, based only on what is said in the audio (names used, self-introductions, stated role/company), the channel they appear on (left = remote, right = local), and the supplied context when it lines up. State the evidence briefly. If there is no basis, say 'identity not stated in audio'. Clearly label these as guesses.

    {{CONTEXT}}
    """

    /// Render `template` for one recording: fill `{{CHANNEL_LAYOUT}}` and
    /// `{{CONTEXT}}` from `context`. Empty substitutions leave no blank gaps; a
    /// non-empty context with no `{{CONTEXT}}` placeholder is appended at the end
    /// so calendar context is never silently dropped.
    static func makePrompt(context: Context, template: String = defaultPromptTemplate) -> String {
        let base = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultPromptTemplate : template

        let localName = context.localSpeakerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasName = (localName?.isEmpty == false)

        // {{CHANNEL_LAYOUT}}
        let rightChannelLine = hasName
            ? "- RIGHT channel = the local microphone: the person making this recording (usually \(localName!)), plus anyone physically in the room."
            : "- RIGHT channel = the local microphone: the person making this recording, plus anyone physically in the room."
        let channelLayout = [
            "Channel layout (important — use it to separate speakers):",
            "- LEFT channel = desktop / system audio: typically the REMOTE participants heard through the speakers (e.g. people on a video call).",
            rightChannelLine,
        ].joined(separator: "\n")

        // {{CONTEXT}}
        var ctx: [String] = []
        if hasName {
            ctx.append("- The local speaker (right channel) is usually \(localName!); the right-channel voice is most likely \(localName!) unless the audio clearly indicates otherwise.")
        }
        if let title = context.meetingTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            ctx.append("- Meeting title: \(title)")
        }
        if !context.attendees.isEmpty {
            ctx.append("- Invited attendees (from the calendar event): \(context.attendees.joined(separator: ", ")). Not everyone invited necessarily attended or spoke — use this only to improve name guesses and to fix mis-heard names.")
        }
        let contextBlock = ctx.isEmpty
            ? ""
            : (["Additional context (use only this, not outside knowledge):"] + ctx).joined(separator: "\n")

        // Substitute.
        var prompt = base.replacingOccurrences(of: "{{CHANNEL_LAYOUT}}", with: channelLayout)
        if prompt.contains("{{CONTEXT}}") {
            prompt = prompt.replacingOccurrences(of: "{{CONTEXT}}", with: contextBlock)
        } else if !contextBlock.isEmpty {
            prompt += "\n\n" + contextBlock
        }

        // Collapse blank gaps left by an empty placeholder, then trim.
        while prompt.contains("\n\n\n") {
            prompt = prompt.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - MIME

    static func mime(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4": return "audio/mp4"
        case "mp3":        return "audio/mpeg"
        case "aac":        return "audio/aac"
        case "wav":        return "audio/wav"
        case "flac":       return "audio/flac"
        case "ogg", "opus": return "audio/ogg"
        default:           return "audio/mp4"
        }
    }
}
