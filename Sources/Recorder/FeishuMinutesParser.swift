import Foundation

enum FeishuMinutesParserError: LocalizedError {
    case invalidJSON(String)
    case missingFileToken
    case missingMinuteURL
    case invalidMinuteURL(String)

    var errorDescription: String? {
        switch self {
        case .invalidJSON(let output):
            return "Could not parse lark-cli JSON output: \(Self.snippet(output))"
        case .missingFileToken:
            return "Drive upload did not return file_token."
        case .missingMinuteURL:
            return "minutes +upload did not return minute_url."
        case .invalidMinuteURL(let url):
            return "Could not extract minute_token from minute_url: \(url)"
        }
    }

    private static func snippet(_ raw: String) -> String {
        let oneLine = raw.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 240 ? String(oneLine.prefix(240)) + "..." : oneLine
    }
}

enum FeishuMinutesParser {
    static func parseJSON(from output: String) throws -> Any {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FeishuMinutesParserError.invalidJSON(output) }

        if let parsed = tryParseJSON(trimmed) {
            return parsed
        }

        for candidate in jsonCandidates(in: trimmed) {
            if let parsed = tryParseJSON(candidate) {
                return parsed
            }
        }

        throw FeishuMinutesParserError.invalidJSON(output)
    }

    static func prettyJSONData(_ json: Any) throws -> Data {
        if JSONSerialization.isValidJSONObject(json) {
            return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        }
        return try JSONSerialization.data(withJSONObject: ["value": json], options: [.prettyPrinted, .sortedKeys])
    }

    static func extractFileToken(from json: Any) throws -> String {
        if let token = firstString(in: json, whereKey: { $0 == "file_token" || $0 == "fileToken" }) {
            return token
        }
        throw FeishuMinutesParserError.missingFileToken
    }

    static func extractMinuteURL(from json: Any) throws -> URL {
        if let urlString = firstString(in: json, whereKey: { $0 == "minute_url" || $0 == "minuteUrl" }),
           let url = URL(string: urlString) {
            return url
        }
        if let urlString = firstStringValue(in: json, whereValue: { $0.contains("/minutes/") }),
           let url = URL(string: urlString) {
            return url
        }
        throw FeishuMinutesParserError.missingMinuteURL
    }

    static func minuteToken(from minuteURL: URL) throws -> String {
        let components = minuteURL.pathComponents.filter { $0 != "/" }
        if let minutesIndex = components.firstIndex(of: "minutes") {
            let tokenIndex = components.index(after: minutesIndex)
            if tokenIndex < components.endIndex {
                let token = components[tokenIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                if !token.isEmpty { return token }
            }
        }
        if let last = components.last, !last.isEmpty {
            return last
        }
        throw FeishuMinutesParserError.invalidMinuteURL(minuteURL.absoluteString)
    }

    static func extractTranscriptMarkdown(from json: Any, folderURL: URL) -> String? {
        if let path = firstString(in: json, whereKey: { $0 == "transcript_file" || $0 == "transcriptFile" }) {
            let transcriptURL = path.hasPrefix("/")
                ? URL(fileURLWithPath: path)
                : folderURL.appendingPathComponent(path)
            if let text = try? String(contentsOf: transcriptURL, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "# Transcript\n\n" + text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            }
        }

        if let transcript = firstValue(in: json, whereKey: { key in
            ["transcript", "transcripts", "transcript_text", "transcriptText"].contains(key)
        }) {
            return "# Transcript\n\n" + markdown(from: transcript).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }

        return nil
    }

    static func extractSummaryMarkdown(from json: Any) -> String? {
        guard let summary = firstValue(in: json, whereKey: { $0 == "summary" || $0 == "summaries" }) else {
            return nil
        }
        let body = markdown(from: summary).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return "# Summary\n\n" + body + "\n"
    }

    static func containsMinuteNotReady(_ json: Any) -> Bool {
        containsString(in: json) {
            $0.localizedCaseInsensitiveContains("minute not ready")
        }
    }

    static func markdown(from value: Any, indent: Int = 0) -> String {
        let prefix = String(repeating: "  ", count: indent)

        if value is NSNull { return "" }

        if let string = value as? String {
            return string
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        if let array = value as? [Any] {
            return array
                .map { item in
                    let rendered = markdown(from: item, indent: indent + 1)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rendered.isEmpty else { return "" }
                    if rendered.contains("\n") {
                        return "\(prefix)- \(rendered.replacingOccurrences(of: "\n", with: "\n\(prefix)  "))"
                    }
                    return "\(prefix)- \(rendered)"
                }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }

        if let dictionary = value as? [String: Any] {
            if let text = preferredText(from: dictionary) {
                return text
            }

            return dictionary.keys.sorted()
                .compactMap { key -> String? in
                    guard !["id", "todo_id", "token"].contains(key) else { return nil }
                    let rendered = markdown(from: dictionary[key] as Any, indent: indent + 1)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !rendered.isEmpty else { return nil }
                    if rendered.contains("\n") {
                        return "\(prefix)- **\(key):**\n\(rendered)"
                    }
                    return "\(prefix)- **\(key):** \(rendered)"
                }
                .joined(separator: "\n")
        }

        return "\(value)"
    }

    private static func preferredText(from dictionary: [String: Any]) -> String? {
        for key in ["text", "content", "summary", "title", "abstract"] {
            if let text = dictionary[key] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    private static func tryParseJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func jsonCandidates(in text: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var lineStart = text.startIndex
        var candidates: [String] = []

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("{") || trimmedLine.hasPrefix("[") {
                candidates.append(String(text[lineStart...]))
            }
            lineStart = text.index(lineStart, offsetBy: line.count)
            if lineStart < text.endIndex, text[lineStart] == "\n" {
                lineStart = text.index(after: lineStart)
            }
        }

        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            candidates.append(String(text[start...end]))
        }

        if let start = text.firstIndex(of: "["),
           let end = text.lastIndex(of: "]") {
            candidates.append(String(text[start...end]))
        }

        return candidates
    }

    private static func firstString(
        in value: Any,
        whereKey keyMatches: (String) -> Bool
    ) -> String? {
        firstValue(in: value, whereKey: keyMatches) as? String
    }

    private static func firstStringValue(
        in value: Any,
        whereValue valueMatches: (String) -> Bool
    ) -> String? {
        if let string = value as? String, valueMatches(string) {
            return string
        }
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                if let match = firstStringValue(in: dictionary[key] as Any, whereValue: valueMatches) {
                    return match
                }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let match = firstStringValue(in: item, whereValue: valueMatches) {
                    return match
                }
            }
        }
        return nil
    }

    private static func containsString(
        in value: Any,
        whereValue valueMatches: (String) -> Bool
    ) -> Bool {
        if let string = value as? String {
            return valueMatches(string)
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { containsString(in: $0, whereValue: valueMatches) }
        }
        if let array = value as? [Any] {
            return array.contains { containsString(in: $0, whereValue: valueMatches) }
        }
        return false
    }

    private static func firstValue(
        in value: Any,
        whereKey keyMatches: (String) -> Bool
    ) -> Any? {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() where keyMatches(key) {
                return dictionary[key]
            }
            for key in dictionary.keys.sorted() {
                if let match = firstValue(in: dictionary[key] as Any, whereKey: keyMatches) {
                    return match
                }
            }
        }
        if let array = value as? [Any] {
            for item in array {
                if let match = firstValue(in: item, whereKey: keyMatches) {
                    return match
                }
            }
        }
        return nil
    }
}
