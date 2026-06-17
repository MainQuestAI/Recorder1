import SwiftUI

/// The content of the dedicated Preferences window.
struct PreferencesView: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label(model.text("tab.general"), systemImage: "gearshape") }

            FeishuPreferences()
                .tabItem { Label(model.text("tab.feishu"), systemImage: "arrow.up.doc") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - General

private struct GeneralPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker(model.text("language.label"), selection: $model.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text(model.text("section.language"))
            }

            Section {
                Picker(model.text("microphone.input"), selection: $model.preferredInputDeviceUID) {
                    Text(defaultInputLabel)
                        .tag("")
                    ForEach(model.inputDevices) { device in
                        Text(deviceLabel(device))
                            .tag(device.uid)
                    }
                }

                HStack {
                    Text(model.text("microphone.note"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.refreshInputDevices()
                    } label: {
                        Label(model.text("microphone.refresh"), systemImage: "arrow.clockwise")
                    }
                    .controlSize(.small)
                }
            } header: {
                Text(model.text("section.microphone"))
            }

            Section {
                Toggle(model.text("autoStop.enabled"), isOn: $model.silenceAutoStopEnabled)

                if model.silenceAutoStopEnabled {
                    Stepper(
                        value: Binding(
                            get: { Int((model.silenceTimeout / 60).rounded()) },
                            set: { model.silenceTimeout = TimeInterval(max(1, $0) * 60) }
                        ),
                        in: 1...60
                    ) {
                        Text(model.text("autoStop.after", Int((model.silenceTimeout / 60).rounded())))
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(model.text("autoStop.threshold"))
                            Spacer()
                            Text("\(Int(model.silenceThresholdDB)) dB")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $model.silenceThresholdDB, in: -80 ... -20, step: 1)
                        Text(model.text("autoStop.note"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(model.text("section.autoStop"))
            }
        }
        .formStyle(.grouped)
    }

    private var defaultInputLabel: String {
        "\(model.text("microphone.systemDefault")) · \(model.selectedInputDeviceDisplayName)"
    }

    private func deviceLabel(_ device: AudioInputDeviceInfo) -> String {
        var label = device.name
        if device.isDefault {
            label += " · \(model.text("microphone.systemDefault"))"
        }
        if device.sampleRate > 0 {
            label += " · \(Int(device.sampleRate)) Hz"
        }
        return label
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
                    model.text("field.larkPath"),
                    text: $model.larkCLIPath,
                    prompt: Text(model.text("field.larkPathPrompt"))
                )
                Text(model.text("cli.note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(model.text("section.cli"))
            }

            Section {
                Toggle(model.text("setting.autoUpload"), isOn: $model.autoUploadAfterSave)
                Toggle(model.text("setting.fetchNotes"), isOn: $model.fetchNotesAfterUpload)
            } header: {
                Text(model.text("section.workflow"))
            }

            Section {
                Toggle(model.text("setting.copyMinute"), isOn: $model.copyMinuteURLAfterUpload)
                Toggle(model.text("setting.openMinute"), isOn: $model.openMinuteURLAfterUpload)
            } header: {
                Text(model.text("section.afterUpload"))
            }
        }
        .formStyle(.grouped)
    }
}
