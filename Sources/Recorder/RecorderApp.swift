import SwiftUI

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = RecorderModel()

    var body: some Scene {
        MenuBarExtra("Recorder", systemImage: menuBarSymbol) {
            RecorderPanel()
                .environment(model)
                .task { model.onAppear() }
        }
        .menuBarExtraStyle(.window)
    }

    /// Menu-bar glyph: a microphone at rest, the record dot while recording,
    /// the pause glyph while paused.
    private var menuBarSymbol: String {
        switch model.state {
        case .idle:      return "mic.fill"
        case .recording: return "record.circle.fill"
        case .paused:    return "pause.circle.fill"
        }
    }
}
