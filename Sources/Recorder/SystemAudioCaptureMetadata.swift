import Foundation

enum SystemAudioTapKind: String, Codable, Equatable {
    case global
    case deviceBound = "device_bound"
    case processMixdown = "process_mixdown"
}

enum SystemAudioDeviceRole: String, Codable, Equatable {
    case defaultOutput = "default_output"
    case defaultSystemOutput = "default_system_output"
}

struct SystemAudioCaptureConfig: Codable, Equatable {
    var tapKind: SystemAudioTapKind
    var deviceRole: SystemAudioDeviceRole
    var includeSubDevice: Bool

    enum CodingKeys: String, CodingKey {
        case tapKind = "tap_kind"
        case deviceRole = "device_role"
        case includeSubDevice = "include_subdevice"
    }
}

struct SystemAudioTapFormatSummary: Codable, Equatable {
    var sampleRate: Double
    var channelCount: Int
    var isInterleaved: Bool
    var commonFormat: String

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case channelCount = "channel_count"
        case isInterleaved = "is_interleaved"
        case commonFormat = "common_format"
    }
}

struct SystemAudioDeviceSnapshot: Codable, Equatable {
    var id: UInt32
    var uid: String
    var name: String
    var sampleRate: Double
    var isRunningSomewhere: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case uid
        case name
        case sampleRate = "sample_rate"
        case isRunningSomewhere = "is_running_somewhere"
    }
}

struct SystemAudioRouteChangeEvent: Codable, Equatable {
    var at: Date
    var reason: String
    var before: SystemAudioDeviceSnapshot?
    var after: SystemAudioDeviceSnapshot?

    enum CodingKeys: String, CodingKey {
        case at
        case reason
        case before
        case after
    }
}

struct SystemAudioCaptureMetadata: Codable, Equatable {
    var config: SystemAudioCaptureConfig?
    var device: SystemAudioDeviceSnapshot?
    var tapFormat: SystemAudioTapFormatSummary?
    var fallbackEvents: [String]
    var routeChanges: [SystemAudioRouteChangeEvent]
    var systemAudioCaptureFailed: Bool
    var lastFailureReason: String?

    enum CodingKeys: String, CodingKey {
        case config
        case device
        case tapFormat = "tap_format"
        case fallbackEvents = "fallback_events"
        case routeChanges = "route_changes"
        case systemAudioCaptureFailed = "system_audio_capture_failed"
        case lastFailureReason = "last_failure_reason"
    }

    static var empty: SystemAudioCaptureMetadata {
        SystemAudioCaptureMetadata(
            config: nil,
            device: nil,
            tapFormat: nil,
            fallbackEvents: [],
            routeChanges: [],
            systemAudioCaptureFailed: false,
            lastFailureReason: nil
        )
    }
}

struct CaptureIntegrity: Codable, Equatable {
    var recordingAcceptance: String
    var issues: [String]
    var requiresUploadConfirmation: Bool

    enum CodingKeys: String, CodingKey {
        case recordingAcceptance = "recording_acceptance"
        case issues
        case requiresUploadConfirmation = "requires_upload_confirmation"
    }

    static func passed() -> CaptureIntegrity {
        CaptureIntegrity(
            recordingAcceptance: "passed",
            issues: [],
            requiresUploadConfirmation: false
        )
    }

    static func degraded(issues: [String]) -> CaptureIntegrity {
        CaptureIntegrity(
            recordingAcceptance: "degraded",
            issues: issues,
            requiresUploadConfirmation: true
        )
    }
}
