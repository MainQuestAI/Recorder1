import Foundation

/// Typed wrapper over `UserDefaults` for the app's persisted preferences.
///
/// Keys + sensible defaults live here in one place; `RecorderModel` mirrors these
/// into `@Observable` properties (loading them at launch, writing them back on
/// change) so the UI can bind to them while disk persistence stays out of band.
enum Preferences {
    private static let defaults = UserDefaults.standard

    private enum Key {
        static let speakerName        = "localSpeakerName"
        static let silenceTimeout     = "silenceTimeoutSeconds"
        static let silenceThresholdDB = "silenceThresholdDB"
        static let silenceAutoStop    = "silenceAutoStopEnabled"
        static let autoTranscribe     = "autoTranscribeAfterSave"
    }

    /// Your name — used only as transcription context to label the local voice
    /// (the microphone / right channel) when guessing who said what. Empty means
    /// "don't name the local speaker". There is intentionally NO baked-in default.
    static var speakerName: String {
        get { defaults.string(forKey: Key.speakerName) ?? "" }
        set { defaults.set(newValue, forKey: Key.speakerName) }
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

    /// Whether to transcribe automatically once a recording is saved. Default true.
    static var autoTranscribe: Bool {
        get { defaults.object(forKey: Key.autoTranscribe) == nil ? true : defaults.bool(forKey: Key.autoTranscribe) }
        set { defaults.set(newValue, forKey: Key.autoTranscribe) }
    }
}
