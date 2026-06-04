import SwiftUI
import AppKit

/// The full menu-bar panel UI for the recorder.
///
/// Layout (top -> bottom):
///   1. Header — state badge + elapsed (mm:ss) + status line
///   2. Primary controls — Record (idle) OR Pause/Resume + Save + Trash (recording/paused)
///   3. Two level meters — "Desktop (L)" + "Mic (R)" bound to model.desktopLevel/micLevel
///   4. Meetings list — title + time range, with a per-row record button; in-progress highlighted
///   5. Footer — Recordings folder + Settings… + Quit
///
/// Preferences (your name, Gemini API key, auto-transcribe, the editable prompt,
/// and silence auto-stop) live in a dedicated Preferences window — see
/// `PreferencesView` / `PreferencesWindowController` — opened from the footer's
/// "Settings…" button or ⌘,.
///
/// Pure SwiftUI, compiles under Swift 5 language mode. Reads the shared @Observable model
/// from the environment and never mutates audio objects directly — it only calls the
/// model's intent methods (startRecording / togglePause / saveAndStop / trashAndStop / quit).
struct RecorderPanel: View {
    @Environment(RecorderModel.self) private var model

    private let panelWidth: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            Divider()

            controls

            if showTranscription {
                Divider()
                transcriptionSection
            }

            Divider()

            meters

            Divider()

            meetingsSection

            if !model.recentRecordings.isEmpty {
                Divider()
                recentSection
            }

            Divider()

            footer
        }
        .padding(12)
        .frame(width: panelWidth)
        // Suppress the auto-drawn focus ring on the first control when the
        // menu-bar window opens. (All text entry lives in the Preferences window.)
        .focusEffectDisabled()
    }

    // MARK: - 1. Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            // State indicator dot + label.
            Image(systemName: stateSymbolName)
                .foregroundStyle(stateColor)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 2) {
                Text(stateLabel)
                    .font(.headline)

                if let status = model.statusMessage, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            // Elapsed time, only meaningful while recording / paused.
            if model.state != .idle {
                Text(formattedElapsed(model.elapsed))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(model.state == .paused ? .secondary : .primary)
                    .monospacedDigit()
            }
        }
    }

    private var stateLabel: String {
        switch model.state {
        case .idle:      return "Ready"
        case .recording: return "Recording"
        case .paused:    return "Paused"
        }
    }

    private var stateSymbolName: String {
        switch model.state {
        case .idle:      return "circle"
        case .recording: return "record.circle.fill"
        case .paused:    return "pause.circle.fill"
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .idle:      return .secondary
        case .recording: return .red
        case .paused:    return .orange
        }
    }

    // MARK: - 2. Primary controls

    @ViewBuilder
    private var controls: some View {
        switch model.state {
        case .idle:
            if let current = model.currentMeeting {
                // In a meeting: the primary button auto-tags it; the small
                // secondary button records without attaching to any meeting.
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Button {
                            model.startRecording(meeting: current)
                        } label: {
                            Label("Record Meeting", systemImage: "record.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .keyboardShortcut("r", modifiers: [.command])

                        Button {
                            model.startRecording(meeting: nil)
                        } label: {
                            Image(systemName: "record.circle")
                                .frame(width: 22)
                        }
                        .controlSize(.large)
                        .buttonStyle(.bordered)
                        .help("Record without attaching to a meeting")
                    }
                    Text("Tags this recording as “\(current.title)”.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                // No meeting in progress: a single, plain Record button.
                Button {
                    model.startRecording(meeting: nil)
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut("r", modifiers: [.command])
            }

        case .recording, .paused:
            HStack(spacing: 8) {
                // Pause / Resume toggles between the two recording states.
                Button {
                    model.togglePause()
                } label: {
                    Label(
                        model.state == .paused ? "Resume" : "Pause",
                        systemImage: model.state == .paused ? "play.fill" : "pause.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(.orange)

                // Save + mix.
                Button {
                    model.saveAndStop()
                } label: {
                    Label("Save", systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                // Discard everything.
                Button(role: .destructive) {
                    model.trashAndStop()
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(.red)
                .help("Discard this recording")
            }
        }
    }

    // MARK: - 2b. Transcription

    private var showTranscription: Bool {
        model.transcriptionState != .idle
    }

    @ViewBuilder
    private var transcriptionSection: some View {
        switch model.transcriptionState {
        case .idle:
            EmptyView()

        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Transcribing with Gemini…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }

        case .done(let url):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Transcript ready")
                        .font(.callout.weight(.medium))
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        model.copyTranscriptText()
                    } label: {
                        Label("Copy text", systemImage: "doc.on.clipboard")
                    }
                    .help("Copy the transcript contents to the clipboard")

                    Button {
                        model.copyTranscriptFile()
                    } label: {
                        Label("Copy file", systemImage: "doc.on.doc")
                    }
                    .help("Copy the transcript.md file (paste into Finder, Mail, …)")

                    Button {
                        model.revealTranscript()
                    } label: {
                        Image(systemName: "folder")
                    }
                    .help("Reveal transcript.md in Finder")

                    Spacer()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // Drag handle — drag transcript.md straight into another window
                // (Finder, Mail, an editor, a chat). Falls back to the copy/reveal
                // buttons above if a target doesn't accept the drag.
                transcriptDragHandle(url)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                if model.apiKeyIsSet {
                    Button {
                        model.retryTranscription()
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
    }

    /// A draggable chip representing the transcript file. Dragging it out of the
    /// panel provides the actual file (via `NSItemProvider(contentsOf:)`), so it
    /// can be dropped into Finder, attached in Mail, or inserted into an editor.
    private func transcriptDragHandle(_ url: URL) -> some View {
        let folder = url.deletingLastPathComponent().lastPathComponent
        return HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.tertiary)
                .font(.caption)
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Image(systemName: "arrow.up.forward.app")
                .foregroundStyle(.tertiary)
                .font(.caption)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onDrag {
            NSItemProvider(contentsOf: url) ?? NSItemProvider()
        } preview: {
            Label(url.lastPathComponent, systemImage: "doc.text")
                .padding(8)
        }
        .help("Drag \(folder)/\(url.lastPathComponent) into another app or window")
    }

    // MARK: - 3. Level meters

    private var meters: some View {
        VStack(alignment: .leading, spacing: 8) {
            LevelMeter(label: "Desktop (L)", level: model.desktopLevel, tint: .green)
            LevelMeter(label: "Mic (R)",     level: model.micLevel,     tint: .blue)
        }
    }

    // MARK: - 4. Meetings

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Meetings")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    model.refreshMeetings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh meetings")
            }

            if model.meetings.isEmpty {
                Text("No meetings nearby.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            inProgress: meeting.isInProgress(Date()),
                            canStart: model.state == .idle,
                            onRecord: { model.startRecording(meeting: meeting) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 4b. Recent recordings

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent recordings")
                .font(.subheadline.weight(.semibold))

            VStack(spacing: 2) {
                ForEach(model.recentRecordings) { entry in
                    recentRow(entry)
                }
            }
        }
    }

    @ViewBuilder
    private func recentRow(_ entry: RecordingEntry) -> some View {
        HStack(spacing: 8) {
            // Draggable region: icon + title/subtitle + grip. Dragging it out
            // provides the transcript file (or the audio if there's no transcript).
            HStack(spacing: 8) {
                Image(systemName: entry.hasTranscript ? "doc.text.fill" : "waveform.circle.fill")
                    .foregroundStyle(entry.hasTranscript ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.displayTitle)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(recentSubtitle(entry))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                if entry.hasTranscript {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .onDrag { recentDragProvider(entry) }
            .help(entry.hasTranscript
                  ? "Drag the transcript out, or use ⋯ for more"
                  : "Drag the audio out, or use ⋯ to transcribe")

            // Actions menu.
            Menu {
                if let transcript = entry.transcriptURL {
                    Button { model.copyTextOfFile(transcript) } label: {
                        Label("Copy transcript text", systemImage: "doc.on.clipboard")
                    }
                    Button { model.copyFileToPasteboard(transcript) } label: {
                        Label("Copy transcript file", systemImage: "doc.on.doc")
                    }
                } else if entry.audioURL != nil {
                    Button { model.transcribeExisting(entry) } label: {
                        Label("Transcribe", systemImage: "text.bubble")
                    }
                    .disabled(!model.apiKeyIsSet || model.transcriptionState == .running)
                }
                if let audio = entry.audioURL {
                    Button { model.copyFileToPasteboard(audio) } label: {
                        Label("Copy audio file", systemImage: "waveform")
                    }
                }
                Divider()
                Button { model.reveal(entry.folderURL) } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }

    /// The file dragged out of a recent row: transcript if present, else audio.
    private func recentDragProvider(_ entry: RecordingEntry) -> NSItemProvider {
        if let transcript = entry.transcriptURL {
            return NSItemProvider(contentsOf: transcript) ?? NSItemProvider()
        }
        if let audio = entry.audioURL {
            return NSItemProvider(contentsOf: audio) ?? NSItemProvider()
        }
        return NSItemProvider()
    }

    /// "6/3/26, 10:15 AM · Transcript" — compact date + status.
    private func recentSubtitle(_ entry: RecordingEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let when = formatter.string(from: entry.date)
        let status = entry.hasTranscript ? "Transcript" : (entry.audioURL != nil ? "Audio only" : "Raw only")
        return "\(when) · \(status)"
    }

    // MARK: - 6. Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Button {
                model.openRecordingsFolder()
            } label: {
                Label("Recordings", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .help("Open ~/Documents/Recordings in Finder")

            Spacer()

            Button {
                openPreferences()
            } label: {
                Label("Settings…", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(",", modifiers: [.command])
            .help("Open Preferences")

            Button {
                model.quit()
            } label: {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q", modifiers: [.command])
        }
    }

    /// Open the dedicated Preferences window. The controller handles activating
    /// the app and bringing the window front — necessary for a menu-bar–only
    /// (`.accessory`) app, where windows otherwise open behind other apps.
    private func openPreferences() {
        PreferencesWindowController.shared.show(model: model)
    }

    // MARK: - Formatting helpers

    /// mm:ss (or h:mm:ss past an hour) for the elapsed timer.
    private func formattedElapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - LevelMeter

/// A simple horizontal level meter: a label, a track, and a tinted fill that
/// grows with `level` (0...1). Uses GeometryReader + Capsule so it animates smoothly.
private struct LevelMeter: View {
    let label: String
    let level: Float
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)

            GeometryReader { geo in
                let clamped = CGFloat(max(0, min(1, level)))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(2, geo.size.width * clamped))
                        .animation(.linear(duration: 0.08), value: clamped)
                }
            }
            .frame(height: 8)
        }
    }
}

// MARK: - MeetingRow

/// One meeting in the list: title + time range, with a small record button.
/// The in-progress meeting is highlighted with a tinted background + dot.
private struct MeetingRow: View {
    let meeting: Meeting
    let inProgress: Bool
    let canStart: Bool
    let onRecord: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Live dot for the in-progress meeting.
            Circle()
                .fill(inProgress ? Color.red : Color.clear)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(timeRange(meeting.start, meeting.end))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            // Per-meeting record button. Disabled while a recording is already running.
            Button {
                onRecord()
            } label: {
                Image(systemName: "record.circle")
                    .foregroundStyle(canStart ? Color.red : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canStart)
            .help("Record this meeting")
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(inProgress ? Color.red.opacity(0.10) : Color.clear)
        )
    }

    /// "2:00 – 3:00 PM" style range using the user's locale/short time style.
    private func timeRange(_ start: Date, _ end: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }
}
