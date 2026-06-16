import Foundation

struct FeishuUploadJob: Equatable {
    let audioURL: URL
    let folderURL: URL
    let meetingTitle: String?
    let attendees: [String]
    let startedAt: Date
    let endedAt: Date

    var audioRelativePath: String {
        audioURL.lastPathComponent
    }
}

struct FeishuUploadResult: Equatable {
    let fileToken: String
    let minuteURL: URL
    let minuteToken: String
    let minutesJSONURL: URL
    let transcriptURL: URL?
    let summaryURL: URL?
    let notesFetchError: String?
}
