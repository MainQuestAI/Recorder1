import SwiftUI

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = RecorderModel()

    init() {
        if CommandLine.arguments.contains("--diagnose-system-audio") {
            SystemAudioDiagnostics.runAndExit()
        }
        if CommandLine.arguments.contains("--diagnose-audio-capture-acceptance") {
            SystemAudioDiagnostics.runRecordingAcceptanceAndExit()
        }
        if CommandLine.arguments.contains("--diagnose-system-audio-matrix") {
            SystemAudioMatrixDiagnostics.runAndExit()
        }
    }

    var body: some Scene {
        MenuBarExtra("Meeting Capture", systemImage: menuBarSymbol) {
            RecorderPanel()
                .environment(model)
                .task { model.onAppear() }
        }
        .menuBarExtraStyle(.window)

        // The dedicated Preferences window is an AppKit-managed NSWindow rather than
        // a SwiftUI `Settings` scene — see PreferencesWindowController for why that's
        // more reliable from a menu-bar–only (.accessory) app. It's opened from the
        // panel's "Settings…" button / ⌘,.
    }

    /// Menu-bar glyph tracks capture and Feishu upload state.
    private var menuBarSymbol: String {
        switch model.state {
        case .idle:
            switch model.uploadState {
            case .idle: return "mic.fill"
            case .needsConfirmation: return "exclamationmark.triangle.fill"
            case .running: return "arrow.up.circle.fill"
            case .uploaded: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        case .recording: return "record.circle.fill"
        case .paused:    return "pause.circle.fill"
        }
    }
}
