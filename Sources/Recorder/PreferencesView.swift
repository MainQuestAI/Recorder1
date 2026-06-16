import SwiftUI

/// The content of the dedicated Preferences window.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }

            FeishuPreferences()
                .tabItem { Label("Feishu", systemImage: "arrow.up.doc") }
        }
        .frame(width: 480, height: 380)
    }
}

// MARK: - General

private struct GeneralPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Stop automatically after silence", isOn: $model.silenceAutoStopEnabled)

                if model.silenceAutoStopEnabled {
                    Stepper(
                        value: Binding(
                            get: { Int((model.silenceTimeout / 60).rounded()) },
                            set: { model.silenceTimeout = TimeInterval(max(1, $0) * 60) }
                        ),
                        in: 1...60
                    ) {
                        Text("After \(Int((model.silenceTimeout / 60).rounded())) min of silence on both channels")
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Silence threshold")
                            Spacer()
                            Text("\(Int(model.silenceThresholdDB)) dB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.silenceThresholdDB, in: -80 ... -20, step: 1)
                        Text("A channel counts as silent below this level.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Auto-stop")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Feishu

private struct FeishuPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField(
                    "lark-cli binary path",
                    text: $model.larkCLIPath,
                    prompt: Text("/opt/homebrew/bin/lark-cli or PATH")
                )
                Text("Leave blank to auto-detect Homebrew, npm global, and PATH locations.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("CLI")
            }

            Section {
                Toggle("Auto upload after save", isOn: $model.autoUploadAfterSave)
                Toggle("Fetch notes after upload", isOn: $model.fetchNotesAfterUpload)
            } header: {
                Text("Workflow")
            }

            Section {
                Toggle("Copy minute_url after upload", isOn: $model.copyMinuteURLAfterUpload)
                Toggle("Open minute_url after upload", isOn: $model.openMinuteURLAfterUpload)
            } header: {
                Text("After upload")
            }
        }
        .formStyle(.grouped)
    }
}
