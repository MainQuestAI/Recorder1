import SwiftUI

/// The content of the dedicated **Preferences window**.
///
/// The window itself is an AppKit `NSWindow` hosting this view — see
/// `PreferencesWindowController` for why we don't use SwiftUI's `Settings` scene.
/// Everything that used to live in the menu-bar panel's inline "Settings"
/// disclosure now lives here, opened with ⌘, or the panel's "Settings…" button:
///   - **General** — your name (transcript labelling) + silence auto-stop.
///   - **Transcription** — Gemini API key, auto-transcribe, and the editable prompt.
///
/// Grouped `Form`s in a `TabView` give the standard macOS System-Settings look,
/// and the window has far more room than the 340-pt menu-bar panel (the prompt
/// editor in particular is finally comfortable to edit). The `TabView` is given a
/// single fixed size so the host window doesn't clip the taller (Transcription) tab
/// or leave the window resizing as you switch tabs.
struct PreferencesView: View {
    var body: some View {
        TabView {
            GeneralPreferences()
                .tabItem { Label("General", systemImage: "gearshape") }

            TranscriptionPreferences()
                .tabItem { Label("Transcription", systemImage: "text.bubble") }
        }
        .frame(width: 480, height: 560)
    }
}

// MARK: - General

private struct GeneralPreferences: View {
    @Environment(RecorderModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Your name", text: $model.localSpeakerName, prompt: Text("Optional"))
                Text("Labels your voice — the microphone, on the right channel — when the transcript guesses who said what. Leave blank to omit.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Your name")
            }

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
                        Text("A channel counts as silent below this level. Lower = more tolerant of quiet rooms.")
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

// MARK: - Transcription

private struct TranscriptionPreferences: View {
    @Environment(RecorderModel.self) private var model

    /// Draft text for the API-key SecureField (never stored in the model).
    @State private var keyDraft = ""
    /// Reveal the key field even when a key is already stored (for "Replace").
    @State private var showKeyField = false
    /// Working copy for the prompt editor; committed to the model on blur / close
    /// so we don't rewrite UserDefaults on every keystroke.
    @State private var promptDraft = ""
    @FocusState private var promptFocused: Bool

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                apiKeyRow
            } header: {
                Text("Gemini API key")
            } footer: {
                Text("Stored in the macOS Keychain — never written to disk in plaintext.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Transcribe automatically with Gemini after saving", isOn: $model.autoTranscribe)
                    .disabled(!model.apiKeyIsSet)
                Text(model.apiKeyIsSet
                     ? "Each recording is transcribed as soon as it's saved."
                     : "Add an API key above to enable transcription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Automatic transcription")
            }

            Section {
                promptEditor
            } header: {
                Text("Prompt")
            }
        }
        .formStyle(.grouped)
        .onAppear { promptDraft = model.promptTemplate }
        .onDisappear { commitPromptDraft() }
    }

    // MARK: API key

    @ViewBuilder
    private var apiKeyRow: some View {
        if model.apiKeyIsSet && !showKeyField {
            HStack(spacing: 8) {
                Label("Stored in Keychain", systemImage: "key.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Replace") { showKeyField = true }
                Button("Remove", role: .destructive) { model.clearAPIKey() }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                if !model.apiKeyIsSet {
                    Text("Paste a Google AI Studio key to enable transcription.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    SecureField("AIza…", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        model.saveAPIKey(keyDraft)
                        keyDraft = ""
                        showKeyField = false
                    }
                    .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    if showKeyField {
                        Button("Cancel") {
                            keyDraft = ""
                            showKeyField = false
                        }
                    }
                }
            }
        }
    }

    // MARK: Prompt editor

    private var promptEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            (Text("The placeholders ")
             + Text("{{CHANNEL_LAYOUT}}").bold().monospaced()
             + Text(" and ")
             + Text("{{CONTEXT}}").bold().monospaced()
             + Text(" are filled in automatically with the stereo layout, your name, and the meeting's title + attendees."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $promptDraft)
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 260)
                .focused($promptFocused)
                .padding(4)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .onChange(of: promptFocused) { _, focused in
                    if !focused { commitPromptDraft() }
                }

            HStack {
                if model.promptTemplateIsCustomized {
                    Label("Customized", systemImage: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Using the built-in prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset to default") {
                    model.resetPromptTemplate()
                    promptDraft = model.promptTemplate
                }
                .disabled(!model.promptTemplateIsCustomized)
            }
        }
    }

    /// Push the editor's working copy into the model (and thus UserDefaults).
    /// A blank draft normalizes back to the default so the "Customized" state and
    /// the actual transcription prompt never disagree.
    private func commitPromptDraft() {
        let trimmed = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? GeminiTranscriber.defaultPromptTemplate : promptDraft
        if model.promptTemplate != resolved { model.promptTemplate = resolved }
        if promptDraft != resolved { promptDraft = resolved }
    }
}
