import Foundation

struct CLIExecutable: Equatable {
    let url: URL
    let prefixArguments: [String]
}

struct CLIProcessResult: Equatable {
    let executable: CLIExecutable
    let arguments: [String]
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var commandLine: String {
        ([executable.url.path] + executable.prefixArguments + arguments)
            .map(Self.shellQuoted)
            .joined(separator: " ")
    }

    private static func shellQuoted(_ raw: String) -> String {
        if raw.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\""))) == nil {
            return raw
        }
        return "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum CLIProcessError: LocalizedError {
    case binaryNotFound(String)
    case commandFailed(command: String, exitCode: Int32, stdout: String, stderr: String)
    case timedOut(command: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let path):
            return "lark-cli not found at \(path)."
        case .commandFailed(let command, let exitCode, let stdout, let stderr):
            let detail = [stderr, stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first(where: { !$0.isEmpty }) ?? "No output."
            return "\(command) failed with exit \(exitCode): \(detail)"
        case .timedOut(let command, let seconds):
            return "\(command) timed out after \(Int(seconds)) seconds."
        }
    }
}

struct CLIProcessRunner {
    var timeoutSeconds: TimeInterval = 3600

    func run(
        executable: CLIExecutable,
        arguments: [String],
        workingDirectory: URL
    ) async throws -> CLIProcessResult {
        try await Task.detached(priority: .utility) {
            try runBlocking(
                executable: executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                timeoutSeconds: timeoutSeconds
            )
        }.value
    }

    static func resolveLarkCLI(configuredPath: String) throws -> CLIExecutable {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
            guard FileManager.default.isExecutableFile(atPath: url.path) else {
                throw CLIProcessError.binaryNotFound(url.path)
            }
            return CLIExecutable(url: url, prefixArguments: [])
        }

        let candidates = [
            "/opt/homebrew/bin/lark-cli",
            "/usr/local/bin/lark-cli",
            "\(NSHomeDirectory())/.npm-global/bin/lark-cli",
            "\(NSHomeDirectory())/.local/bin/lark-cli",
        ]
        if let match = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return CLIExecutable(url: URL(fileURLWithPath: match), prefixArguments: [])
        }

        return CLIExecutable(url: URL(fileURLWithPath: "/usr/bin/env"), prefixArguments: ["lark-cli"])
    }

    static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let standardPath = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(NSHomeDirectory())/.npm-global/bin",
            "\(NSHomeDirectory())/.local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ].joined(separator: ":")
        if let existing = environment["PATH"], !existing.isEmpty {
            environment["PATH"] = "\(standardPath):\(existing)"
        } else {
            environment["PATH"] = standardPath
        }
        return environment
    }
}

private func runBlocking(
    executable: CLIExecutable,
    arguments: [String],
    workingDirectory: URL,
    timeoutSeconds: TimeInterval
) throws -> CLIProcessResult {
    let process = Process()
    process.executableURL = executable.url
    process.arguments = executable.prefixArguments + arguments
    process.currentDirectoryURL = workingDirectory
    process.environment = CLIProcessRunner.processEnvironment()

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    let lock = NSLock()
    var stdoutData = Data()
    var stderrData = Data()

    stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        lock.lock()
        stdoutData.append(data)
        lock.unlock()
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        lock.lock()
        stderrData.append(data)
        lock.unlock()
    }

    let resultForError = CLIProcessResult(
        executable: executable,
        arguments: arguments,
        exitCode: -1,
        stdout: "",
        stderr: ""
    )

    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in semaphore.signal() }

    try process.run()

    if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
        process.terminate()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        throw CLIProcessError.timedOut(command: resultForError.commandLine, seconds: timeoutSeconds)
    }

    stdoutPipe.fileHandleForReading.readabilityHandler = nil
    stderrPipe.fileHandleForReading.readabilityHandler = nil
    let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()

    lock.lock()
    stdoutData.append(remainingStdout)
    stderrData.append(remainingStderr)
    let stdout = String(decoding: stdoutData, as: UTF8.self)
    let stderr = String(decoding: stderrData, as: UTF8.self)
    lock.unlock()

    let result = CLIProcessResult(
        executable: executable,
        arguments: arguments,
        exitCode: process.terminationStatus,
        stdout: stdout,
        stderr: stderr
    )
    guard result.exitCode == 0 else {
        throw CLIProcessError.commandFailed(
            command: result.commandLine,
            exitCode: result.exitCode,
            stdout: result.stdout,
            stderr: result.stderr
        )
    }
    return result
}
