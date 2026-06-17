import Foundation

enum RecordingRetentionPolicy: String, CaseIterable, Identifiable, Codable {
    case keepForever = "keep"
    case deleteAfter15Days = "delete_after_15_days"
    case deleteAfter30Days = "delete_after_30_days"

    var id: String { rawValue }

    var retentionDays: Int? {
        switch self {
        case .keepForever:
            return nil
        case .deleteAfter15Days:
            return 15
        case .deleteAfter30Days:
            return 30
        }
    }

    var textKey: String {
        switch self {
        case .keepForever:
            return "retention.keep"
        case .deleteAfter15Days:
            return "retention.delete15"
        case .deleteAfter30Days:
            return "retention.delete30"
        }
    }
}
