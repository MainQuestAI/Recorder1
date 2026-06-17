import SwiftUI
import AppKit

private enum MQTheme {
    static let page = Color(red: 3 / 255, green: 3 / 255, blue: 5 / 255)
    static let elevated = Color.white.opacity(0.03)
    static let surface = Color.white.opacity(0.05)
    static let surfaceHover = Color.white.opacity(0.08)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.15)
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 156 / 255, green: 163 / 255, blue: 175 / 255)
    static let textMuted = Color(red: 107 / 255, green: 114 / 255, blue: 128 / 255)
    static let success = Color(red: 46 / 255, green: 204 / 255, blue: 113 / 255)
    static let warning = Color(red: 241 / 255, green: 196 / 255, blue: 15 / 255)
    static let danger = Color(red: 231 / 255, green: 76 / 255, blue: 60 / 255)
    static let info = Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
    static let panelRadius: CGFloat = 20
    static let cardRadius: CGFloat = 10
    static let buttonRadius: CGFloat = 10
}

private struct MQCard<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: MQTheme.cardRadius, style: .continuous)
                .fill(MQTheme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: MQTheme.cardRadius, style: .continuous)
                        .stroke(MQTheme.border, lineWidth: 1)
                )
        )
    }
}

private struct MQDivider: View {
    var body: some View {
        Rectangle()
            .fill(MQTheme.border)
            .frame(height: 1)
    }
}

private struct MQButtonStyle: ButtonStyle {
    enum Kind {
        case primary(Color)
        case secondary
        case icon
        case danger
    }

    @Environment(\.isEnabled) private var isEnabled
    let kind: Kind
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, compact ? 6 : 8)
            .frame(minHeight: compact ? 28 : 36)
            .background(background(isPressed: configuration.isPressed))
            .clipShape(RoundedRectangle(cornerRadius: MQTheme.buttonRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.42)
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger:
            return MQTheme.textPrimary
        case .secondary, .icon:
            return isEnabled ? MQTheme.textPrimary : MQTheme.textMuted
        }
    }

    private var horizontalPadding: CGFloat {
        switch kind {
        case .icon:
            return compact ? 8 : 10
        default:
            return compact ? 10 : 12
        }
    }

    private func background(isPressed: Bool) -> some View {
        let fill: Color
        let stroke: Color
        switch kind {
        case .primary(let tint):
            fill = tint.opacity(isPressed ? 0.72 : 0.86)
            stroke = tint.opacity(0.72)
        case .secondary:
            fill = isPressed ? MQTheme.surfaceHover : MQTheme.elevated
            stroke = MQTheme.borderStrong
        case .icon:
            fill = isPressed ? MQTheme.surfaceHover : Color.white.opacity(0.02)
            stroke = MQTheme.border
        case .danger:
            fill = MQTheme.danger.opacity(isPressed ? 0.60 : 0.72)
            stroke = MQTheme.danger.opacity(0.7)
        }

        return RoundedRectangle(cornerRadius: MQTheme.buttonRadius, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: MQTheme.buttonRadius, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }
}

/// The full menu-bar panel UI for the recorder.
///
/// Layout (top -> bottom):
///   1. Header — state badge + elapsed (mm:ss) + status line
///   2. Primary controls — Record (idle) OR Pause/Resume + Save + Trash (recording/paused)
///   3. Two level meters — "Desktop (L)" + "Mic (R)" bound to model.desktopLevel/micLevel
///   4. Meetings list — title + time range, with a per-row record button; in-progress highlighted
///   5. Footer — Recorder1 folder + Settings… + Quit
///
/// Preferences (Feishu CLI upload settings and silence auto-stop) live in a dedicated Preferences window — see
/// `PreferencesView` / `PreferencesWindowController` — opened from the footer's
/// "Settings…" button or ⌘,.
///
/// Pure SwiftUI, compiles under Swift 5 language mode. Reads the shared @Observable model
/// from the environment and never mutates audio objects directly — it only calls the
/// model's intent methods (startRecording / togglePause / saveAndStop / trashAndStop / quit).
struct RecorderPanel: View {
    @Environment(RecorderModel.self) private var model

    private let panelWidth: CGFloat = 382

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            controls

            if showUpload {
                uploadSection
            }

            meters

            meetingsSection

            if !model.recentRecordings.isEmpty {
                recentSection
            }

            MQDivider()

            footer
        }
        .padding(14)
        .frame(width: panelWidth)
        .background(
            RoundedRectangle(cornerRadius: MQTheme.panelRadius, style: .continuous)
                .fill(MQTheme.page)
                .overlay(
                    RoundedRectangle(cornerRadius: MQTheme.panelRadius, style: .continuous)
                        .stroke(MQTheme.borderStrong, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.50), radius: 24, y: 12)
        )
        .foregroundStyle(MQTheme.textPrimary)
        .preferredColorScheme(.dark)
        // Suppress the auto-drawn focus ring on the first control when the
        // menu-bar window opens. (All text entry lives in the Preferences window.)
        .focusEffectDisabled()
    }

    // MARK: - 1. Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            // State indicator dot + label.
            ZStack {
                Circle()
                    .fill(stateColor.opacity(0.16))
                    .frame(width: 34, height: 34)
                Image(systemName: stateSymbolName)
                    .foregroundStyle(stateColor)
                    .font(.system(size: 15, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(stateLabel)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MQTheme.textPrimary)

                if let status = model.statusMessage, !status.isEmpty {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(MQTheme.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            // Elapsed time, only meaningful while recording / paused.
            if model.state != .idle {
                Text(formattedElapsed(model.elapsed))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
                    .foregroundStyle(model.state == .paused ? MQTheme.textSecondary : MQTheme.textPrimary)
                    .monospacedDigit()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: MQTheme.buttonRadius, style: .continuous)
                            .fill(MQTheme.elevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: MQTheme.buttonRadius, style: .continuous)
                                    .stroke(MQTheme.border, lineWidth: 1)
                            )
                    )
            }
        }
        .padding(.horizontal, 2)
    }

    private var stateLabel: String {
        switch model.state {
        case .idle:
            switch model.uploadState {
            case .idle: return model.text("state.ready")
            case .needsConfirmation: return model.text("state.audioIncomplete")
            case .running: return model.text("state.uploading")
            case .uploaded: return model.text("state.uploaded")
            case .failed: return model.text("state.uploadFailed")
            }
        case .recording: return model.text("state.recording")
        case .paused:    return model.text("state.paused")
        }
    }

    private var stateSymbolName: String {
        switch model.state {
        case .idle:
            switch model.uploadState {
            case .idle: return "circle"
            case .needsConfirmation: return "exclamationmark.triangle.fill"
            case .running: return "arrow.up.circle.fill"
            case .uploaded: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        case .recording: return "record.circle.fill"
        case .paused:    return "pause.circle.fill"
        }
    }

    private var stateColor: Color {
        switch model.state {
        case .idle:
            switch model.uploadState {
            case .idle: return MQTheme.textMuted
            case .needsConfirmation: return MQTheme.warning
            case .running: return MQTheme.info
            case .uploaded: return MQTheme.success
            case .failed: return MQTheme.warning
            }
        case .recording: return MQTheme.danger
        case .paused:    return MQTheme.warning
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
                MQCard(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            model.startRecording(meeting: current)
                        } label: {
                            Label(model.text("action.recordMeeting"), systemImage: "record.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.large)
                        .buttonStyle(MQButtonStyle(kind: .primary(MQTheme.danger)))
                        .keyboardShortcut("r", modifiers: [.command])

                        Button {
                            model.startRecording(meeting: nil, matchCurrentMeeting: false)
                        } label: {
                            Image(systemName: "record.circle")
                                .frame(width: 22, height: 20)
                        }
                        .controlSize(.large)
                        .buttonStyle(MQButtonStyle(kind: .icon))
                        .help(model.text("action.recordNoMeeting"))
                    }
                    Text(model.text("text.tagRecording", current.title))
                        .font(.caption2)
                        .foregroundStyle(MQTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                // No meeting in progress: a single, plain Record button.
                MQCard {
                    Button {
                        model.startRecording(meeting: nil)
                    } label: {
                        Label(model.text("action.record"), systemImage: "record.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(MQButtonStyle(kind: .primary(MQTheme.danger)))
                    .keyboardShortcut("r", modifiers: [.command])
                }
            }

        case .recording, .paused:
            MQCard {
                HStack(spacing: 8) {
                // Pause / Resume toggles between the two recording states.
                    Button {
                        model.togglePause()
                    } label: {
                        Label(
                            model.state == .paused ? model.text("action.resume") : model.text("action.pause"),
                            systemImage: model.state == .paused ? "play.fill" : "pause.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(MQButtonStyle(kind: .secondary))

                // Save + mix.
                    Button {
                        model.saveAndStop()
                    } label: {
                        Label(model.text("action.stop"), systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .controlSize(.large)
                    .buttonStyle(MQButtonStyle(kind: .primary(MQTheme.info)))

                // Discard everything.
                    Button(role: .destructive) {
                        model.trashAndStop()
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 20, height: 20)
                    }
                    .controlSize(.large)
                    .buttonStyle(MQButtonStyle(kind: .danger))
                    .help(model.text("help.discard"))
                }
            }
        }
    }

    // MARK: - 2b. Feishu upload

    private var showUpload: Bool {
        model.uploadState != .idle
    }

    @ViewBuilder
    private var uploadSection: some View {
        switch model.uploadState {
        case .idle:
            EmptyView()

        case .needsConfirmation(let message):
            MQCard(spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MQTheme.warning)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(MQTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button {
                        model.confirmUploadDespiteDegradedAudio()
                    } label: {
                        Label(model.text("action.uploadAnyway"), systemImage: "arrow.up.circle")
                    }
                    .buttonStyle(MQButtonStyle(kind: .primary(MQTheme.warning), compact: true))

                    Button {
                        model.revealLastUploadFolder()
                    } label: {
                        Image(systemName: "folder")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(MQButtonStyle(kind: .icon, compact: true))
                    .help(model.text("help.revealFolder"))

                    Spacer()
                }
                .controlSize(.small)
            }

        case .running:
            MQCard {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(MQTheme.info)
                    Text(model.text("text.uploadingFeishu"))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(MQTheme.textSecondary)
                    Spacer()
                }
            }

        case .uploaded(let url):
            MQCard(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MQTheme.success)
                    Text(model.text("state.uploaded"))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(MQTheme.textPrimary)
                    Spacer()
                }

                HStack(spacing: 8) {
                    Button {
                        model.openMinuteURL(url)
                    } label: {
                        Label(model.text("action.openMinute"), systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(MQButtonStyle(kind: .primary(MQTheme.success), compact: true))
                    .help(model.text("help.openMinute"))

                    Button {
                        model.copyMinuteURL(url)
                    } label: {
                        Label(model.text("action.copyURL"), systemImage: "link")
                    }
                    .buttonStyle(MQButtonStyle(kind: .secondary, compact: true))
                    .help(model.text("help.copyMinute"))

                    Button {
                        model.revealLastUploadFolder()
                    } label: {
                        Image(systemName: "folder")
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(MQButtonStyle(kind: .icon, compact: true))
                    .help(model.text("help.revealFolder"))

                    Spacer()
                }
                .controlSize(.small)
            }

        case .failed(let message):
            MQCard(spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(MQTheme.warning)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(MQTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
                Button {
                    model.retryUpload()
                } label: {
                    Label(model.text("action.retryUpload"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(MQButtonStyle(kind: .primary(MQTheme.warning), compact: true))
                .controlSize(.small)
            }
        }
    }

    // MARK: - 3. Level meters

    private var meters: some View {
        MQCard(spacing: 9) {
            LevelMeter(label: model.text("meter.desktop"), level: model.desktopLevel, tint: MQTheme.success)
            LevelMeter(label: model.text("meter.mic"), level: model.micLevel, tint: MQTheme.info)
        }
    }

    // MARK: - 4. Meetings

    private var meetingsSection: some View {
        MQCard(spacing: 8) {
            HStack {
                Text(model.text("text.meetings"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MQTheme.textPrimary)
                Spacer()
                Button {
                    model.refreshMeetings()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(MQButtonStyle(kind: .icon, compact: true))
                .help(model.text("help.refreshMeetings"))
            }

            if model.meetings.isEmpty {
                Text(model.text("text.noMeetings"))
                    .font(.caption)
                    .foregroundStyle(MQTheme.textMuted)
                    .padding(.vertical, 2)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.meetings) { meeting in
                        MeetingRow(
                            meeting: meeting,
                            inProgress: meeting.isInProgress(Date()),
                            canStart: model.state == .idle,
                            language: model.language,
                            onRecord: { model.startRecording(meeting: meeting) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - 4b. Recent recordings

    private var recentSection: some View {
        MQCard(spacing: 8) {
            Text(model.text("text.recent"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(MQTheme.textPrimary)

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
            // Draggable region: transcript if present, else audio.
            HStack(spacing: 8) {
                Image(systemName: recentIconName(entry))
                    .foregroundStyle(entry.isUploaded ? MQTheme.success : (entry.hasTranscript ? MQTheme.info : MQTheme.textMuted))

                VStack(alignment: .leading, spacing: 1) {
                    Text(recentTitle(entry))
                        .font(.callout)
                        .foregroundStyle(MQTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(recentSubtitle(entry))
                        .font(.caption2)
                        .foregroundStyle(MQTheme.textSecondary)
                }

                Spacer(minLength: 4)

                if entry.hasTranscript || entry.audioURL != nil {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(MQTheme.textMuted)
                        .font(.caption)
                }
            }
            .contentShape(Rectangle())
            .onDrag { recentDragProvider(entry) }
            .help(model.text("help.dragRecent"))

            // Actions menu.
            Menu {
                if let minuteURL = entry.minuteURL {
                    Button { model.openMinuteURL(minuteURL) } label: {
                        Label(model.text("action.openMinute"), systemImage: "arrow.up.forward.app")
                    }
                    Button { model.copyMinuteURL(minuteURL) } label: {
                        Label(model.text("action.copyMinuteURL"), systemImage: "link")
                    }
                    Divider()
                }

                if let audio = entry.audioURL {
                    Button { model.uploadExisting(entry) } label: {
                        Label(
                            entry.isUploaded ? model.text("action.retryUpload") : model.text("action.uploadToFeishu"),
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(model.uploadState == .running)
                    Button { model.copyFileToPasteboard(audio) } label: {
                        Label(model.text("action.copyAudioFile"), systemImage: "waveform")
                    }
                }

                if let transcript = entry.transcriptURL {
                    Divider()
                    Button { model.copyTextOfFile(transcript) } label: {
                        Label(model.text("action.copyTranscriptText"), systemImage: "doc.on.clipboard")
                    }
                    Button { model.copyFileToPasteboard(transcript) } label: {
                        Label(model.text("action.copyTranscriptFile"), systemImage: "doc.on.doc")
                    }
                }
                Divider()
                Button { model.reveal(entry.folderURL) } label: {
                    Label(model.text("action.revealFinder"), systemImage: "folder")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(MQTheme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(model.text("help.recentActions"))
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(MQTheme.border, lineWidth: 1)
                )
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

    private func recentIconName(_ entry: RecordingEntry) -> String {
        if entry.isUploaded { return "checkmark.circle.fill" }
        if entry.hasTranscript { return "doc.text.fill" }
        return "waveform.circle.fill"
    }

    private func recentTitle(_ entry: RecordingEntry) -> String {
        if let title = entry.title, !title.isEmpty {
            return title
        }
        return model.text("text.recordingFallback")
    }

    /// "6/3/26, 10:15 AM · Uploaded" — compact date + status.
    private func recentSubtitle(_ entry: RecordingEntry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let when = formatter.string(from: entry.date)
        let status: String
        if entry.isUploaded {
            status = model.text("recent.uploaded")
        } else if entry.uploadStatus == "failed" {
            status = model.text("recent.uploadFailed")
        } else if entry.audioURL != nil {
            status = model.text("recent.audioReady")
        } else {
            status = model.text("recent.rawOnly")
        }
        return "\(when) · \(status)"
    }

    // MARK: - 6. Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                model.openRecordingsFolder()
            } label: {
                Label(model.text("action.recordings"), systemImage: "folder")
            }
            .buttonStyle(MQButtonStyle(kind: .secondary, compact: true))
            .help(model.text("help.openFolder"))

            Spacer()

            Button {
                openPreferences()
            } label: {
                Label(model.text("action.settings"), systemImage: "gearshape")
            }
            .buttonStyle(MQButtonStyle(kind: .icon, compact: true))
            .keyboardShortcut(",", modifiers: [.command])
            .help(model.text("help.openPreferences"))

            Button {
                model.quit()
            } label: {
                Label(model.text("action.quit"), systemImage: "power")
            }
            .buttonStyle(MQButtonStyle(kind: .icon, compact: true))
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
                .foregroundStyle(MQTheme.textSecondary)

            GeometryReader { geo in
                let clamped = CGFloat(max(0, min(1, level)))
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.72), tint],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
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
    let language: AppLanguage
    let onRecord: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Live dot for the in-progress meeting.
            Circle()
                .fill(inProgress ? MQTheme.danger : Color.clear)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 1) {
                Text(meeting.title)
                    .font(.callout)
                    .foregroundStyle(MQTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(timeRange(meeting.start, meeting.end))
                    .font(.caption2)
                    .foregroundStyle(MQTheme.textSecondary)
            }

            Spacer(minLength: 4)

            // Per-meeting record button. Disabled while a recording is already running.
            Button {
                onRecord()
            } label: {
                Image(systemName: "record.circle")
                    .frame(width: 18, height: 18)
                    .foregroundStyle(canStart ? MQTheme.danger : MQTheme.textMuted)
            }
            .buttonStyle(MQButtonStyle(kind: .icon, compact: true))
            .disabled(!canStart)
            .help(text("help.recordThisMeeting"))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(inProgress ? MQTheme.danger.opacity(0.10) : Color.white.opacity(0.02))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(inProgress ? MQTheme.danger.opacity(0.32) : MQTheme.border, lineWidth: 1)
                )
        )
    }

    /// "2:00 – 3:00 PM" style range using the user's locale/short time style.
    private func timeRange(_ start: Date, _ end: Date) -> String {
        let fmt = DateFormatter()
        fmt.timeStyle = .short
        fmt.dateStyle = .none
        return "\(fmt.string(from: start)) – \(fmt.string(from: end))"
    }

    private func text(_ key: String) -> String {
        AppText.t(key, language)
    }
}
