import Foundation

func writeStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func appendInvocation(_ line: String) throws {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("fake-lark-invocations.log")
    let data = Data((line + "\n").utf8)
    if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    } else {
        try data.write(to: url, options: .atomic)
    }
}

func value(after flag: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: flag) else { return nil }
    let next = args.index(after: index)
    guard next < args.endIndex else { return nil }
    return args[next]
}

func exitWithError(_ message: String, code: Int32) -> Never {
    writeStderr(message)
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
try appendInvocation("\(FileManager.default.currentDirectoryPath) :: \(args.joined(separator: " "))")

guard args.count >= 2 else {
    exitWithError("missing command", code: 99)
}

let command = "\(args[0]) \(args[1])"
let rest = Array(args.dropFirst(2))
let fm = FileManager.default
let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)

switch command {
case "drive +upload":
    let file = value(after: "--file", in: rest) ?? ""
    guard file.hasSuffix(".m4a") else {
        exitWithError("expected an m4a upload file, got: \(file)", code: 11)
    }
    guard fm.fileExists(atPath: cwd.appendingPathComponent(file).path) else {
        exitWithError("\(file) missing in working directory", code: 12)
    }
    if file != "audio.m4a" {
        let source = cwd.appendingPathComponent("audio.m4a")
        let upload = cwd.appendingPathComponent(file)
        guard (try? Data(contentsOf: source)) == (try? Data(contentsOf: upload)) else {
            exitWithError("upload copy does not match audio.m4a", code: 13)
        }
    }
    let failOnce = cwd.appendingPathComponent("fail-drive-once")
    if fm.fileExists(atPath: failOnce.path) {
        try? fm.removeItem(at: failOnce)
        exitWithError("forced drive upload failure", code: 23)
    }
    writeStderr("Uploading: \(file) (probe) -> Drive root folder")
    print("""
    {
      "ok": true,
      "identity": "user",
      "data": {
        "file_name": "\(file)",
        "file_token": "fake-file-token",
        "size": 31,
        "url": "https://my.feishu.cn/file/fake-file-token",
        "version": "fake-version"
      }
    }
    """)

case "minutes +upload":
    let fileToken = value(after: "--file-token", in: rest) ?? ""
    guard fileToken == "fake-file-token" else {
        exitWithError("expected fake-file-token, got: \(fileToken)", code: 31)
    }
    print("""
    {
      "ok": true,
      "identity": "user",
      "data": {
        "minute_url": "https://example.feishu.cn/minutes/fake-minute-token"
      }
    }
    """)

case "vc +notes":
    let minuteToken = value(after: "--minute-tokens", in: rest) ?? ""
    guard minuteToken == "fake-minute-token" else {
        exitWithError("expected fake-minute-token, got: \(minuteToken)", code: 41)
    }
    let transcriptFolder = cwd.appendingPathComponent("minutes/fake-minute-token", isDirectory: true)
    try fm.createDirectory(at: transcriptFolder, withIntermediateDirectories: true)
    try "Retry upload probe transcript\n".write(
        to: transcriptFolder.appendingPathComponent("transcript.txt"),
        atomically: true,
        encoding: .utf8
    )
    writeStderr("[vc +notes] writing transcript: minutes/fake-minute-token/transcript.txt")
    print("""
    {
      "ok": true,
      "identity": "user",
      "data": {
        "notes": [
          {
            "artifacts": {
              "transcript_file": "minutes/fake-minute-token/transcript.txt"
            },
            "minute_token": "fake-minute-token",
            "title": "Retry upload probe"
          }
        ]
      },
      "meta": {
        "count": 1
      }
    }
    """)

default:
    exitWithError("unexpected fake lark-cli command: \(args.joined(separator: " "))", code: 99)
}
