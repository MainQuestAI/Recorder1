import Foundation

/// Typed wrapper over `UserDefaults` for the app's persisted preferences.
///
/// Keys + sensible defaults live here in one place; `RecorderModel` mirrors these
/// into `@Observable` properties (loading them at launch, writing them back on
/// change) so the UI can bind to them while disk persistence stays out of band.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let silenceTimeout     = "silenceTimeoutSeconds"
        static let silenceThresholdDB = "silenceThresholdDB"
        static let silenceAutoStop    = "silenceAutoStopEnabled"
        static let larkCLIPath        = "larkCLIBinaryPath"
        static let autoUpload         = "autoUploadAfterSave"
        static let fetchNotes         = "fetchNotesAfterUpload"
        static let copyMinuteURL      = "copyMinuteURLAfterUpload"
        static let openMinuteURL      = "openMinuteURLAfterUpload"
        static let language           = "appLanguage"
        static let inputDeviceUID     = "preferredInputDeviceUID"
    }

    /// Seconds of two-channel silence before a recording auto-stops. Default 300 (5 min).
    static var silenceTimeout: TimeInterval {
        get { defaults.object(forKey: Key.silenceTimeout) == nil ? 300 : defaults.double(forKey: Key.silenceTimeout) }
        set { defaults.set(newValue, forKey: Key.silenceTimeout) }
    }

    /// dBFS below which a channel counts as silent. Default -50.
    static var silenceThresholdDB: Float {
        get { defaults.object(forKey: Key.silenceThresholdDB) == nil ? -50 : defaults.float(forKey: Key.silenceThresholdDB) }
        set { defaults.set(newValue, forKey: Key.silenceThresholdDB) }
    }

    /// Whether silence auto-stop is active at all. Default true.
    static var silenceAutoStop: Bool {
        get { defaults.object(forKey: Key.silenceAutoStop) == nil ? true : defaults.bool(forKey: Key.silenceAutoStop) }
        set { defaults.set(newValue, forKey: Key.silenceAutoStop) }
    }

    /// Empty means auto-resolve: /opt/homebrew/bin/lark-cli first, then PATH.
    static var larkCLIPath: String {
        get { defaults.string(forKey: Key.larkCLIPath) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.larkCLIPath) }
    }

    /// Whether to upload audio.m4a automatically once it is saved. Default true.
    static var autoUploadAfterSave: Bool {
        get { defaults.object(forKey: Key.autoUpload) == nil ? true : defaults.bool(forKey: Key.autoUpload) }
        set { defaults.set(newValue, forKey: Key.autoUpload) }
    }

    /// Whether to call vc +notes after creating the minute. Default true.
    static var fetchNotesAfterUpload: Bool {
        get { defaults.object(forKey: Key.fetchNotes) == nil ? true : defaults.bool(forKey: Key.fetchNotes) }
        set { defaults.set(newValue, forKey: Key.fetchNotes) }
    }

    /// Copy the minute URL to the clipboard after upload. Default false.
    static var copyMinuteURLAfterUpload: Bool {
        get { defaults.object(forKey: Key.copyMinuteURL) == nil ? false : defaults.bool(forKey: Key.copyMinuteURL) }
        set { defaults.set(newValue, forKey: Key.copyMinuteURL) }
    }

    /// Open the minute URL after upload. Default false.
    static var openMinuteURLAfterUpload: Bool {
        get { defaults.object(forKey: Key.openMinuteURL) == nil ? false : defaults.bool(forKey: Key.openMinuteURL) }
        set { defaults.set(newValue, forKey: Key.openMinuteURL) }
    }

    /// UI language. Default Chinese.
    static var language: AppLanguage {
        get {
            guard let raw = defaults.string(forKey: Key.language),
                  let language = AppLanguage(rawValue: raw) else {
                return .zh
            }
            return language
        }
        set { defaults.set(newValue.rawValue, forKey: Key.language) }
    }

    /// Empty means use the macOS default input device.
    static var preferredInputDeviceUID: String {
        get { defaults.string(forKey: Key.inputDeviceUID) ?? "" }
        set { defaults.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Key.inputDeviceUID) }
    }
}
