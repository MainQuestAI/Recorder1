# From Recorder To Recorder1

This document explains how Recorder1 adapts the upstream [tobi/recorder](https://github.com/tobi/recorder) project.

## Summary

The upstream Recorder project is a native macOS menu-bar recorder. It captures system audio and microphone audio into separate raw files, mixes them into a stereo `audio.m4a`, and can transcribe the result with Gemini.

Recorder1 keeps the local recording architecture and changes the post-recording workflow:

```text
Upstream Recorder:
  record meeting audio -> audio.m4a -> Gemini transcription

Recorder1:
  record meeting audio -> audio.m4a -> Feishu Drive -> Feishu Minutes -> local notes
```

## What Stayed From Upstream

Recorder1 intentionally keeps the core native macOS recording design:

- Swift / SwiftUI menu-bar app.
- No Dock icon.
- One-click start/stop recording.
- Calendar-aware meeting context.
- Separate raw source files:
  - `desktop.caf`
  - `mic.caf`
- Final stereo mix:
  - left channel = system audio
  - right channel = microphone audio
- Core Audio system-output capture.
- AVAudioEngine microphone capture.
- Local recordings library.
- Meeting-end notification support.
- Silence auto-stop support.

These pieces remain the local recording foundation of Recorder1.

## What Was Removed

Recorder1 removes the Gemini transcription path from the user-facing product:

- Gemini API key setting.
- Gemini Files API uploader.
- Gemini diarization prompt.
- Keychain storage for the Gemini API key.
- Auto-transcribe setting.

The goal is to avoid maintaining two transcript backends in the MVP. Feishu Minutes becomes the only post-recording transcription workflow.

## What Was Added

### Feishu Minutes Upload

Recorder1 adds a `lark-cli` based upload flow:

1. Copy `audio.m4a` to a meeting-named `.m4a` file, then upload that file to Feishu Drive:

   ```bash
   lark-cli drive +upload --as user --file <YYYY-MM-DD_HHmm-meeting-title.m4a> --json
   ```

2. Create a Feishu Minute from the Drive file:

   ```bash
   lark-cli minutes +upload --as user --file-token <file_token> --json
   ```

3. Extract `minute_token` from `minute_url`.

4. Optionally fetch notes and transcript artifacts:

   ```bash
   lark-cli vc +notes --as user --minute-tokens <minute_token> --overwrite --json
   ```

5. Write local files:

   ```text
   feishu_minutes.json
   transcript.md
   summary.md
   upload.log
   metadata.json
   ```

Related files:

- `FeishuCLIUploader.swift`
- `FeishuUploadJob.swift`
- `CLIProcessRunner.swift`
- `FeishuMinutesParser.swift`
- `UploadStatusStore.swift`

### Capture Integrity Guard

Recorder1 analyzes the final `audio.m4a` after mixing.

If system audio is silent while microphone audio is present, the app marks the recording as degraded and blocks automatic upload until the user confirms.

Related files:

- `AudioQualityAnalyzer.swift`
- `UploadStatusStore.swift`
- `RecorderModel.swift`

### System Audio Diagnostics

Recorder1 adds app-binary diagnostics for system audio capture:

```bash
/Applications/Recorder1.app/Contents/MacOS/Recorder \
  --diagnose-system-audio-matrix \
  --diagnose-output /tmp/recorder1-system-audio-matrix.json
```

The matrix checks global tap, device-bound tap, and process mixdown variants under the installed app's real signing identity.

Related files:

- `SystemAudioDiagnostics.swift`
- `SystemAudioMatrixDiagnostics.swift`
- `SystemAudioCaptureMetadata.swift`
- `scripts/build-for-audio-capture-acceptance.sh`
- `scripts/verify-audio-capture-acceptance.sh`

### Output Route Handling

Recorder1 listens for output-device changes during recording. When the output route changes, it logs the change, rebuilds the tap/aggregate path, and records route metadata.

Related files:

- `SystemAudioTap.swift`
- `SystemAudioCaptureMetadata.swift`
- `UploadStatusStore.swift`

### Microphone Input Selection

Recorder1 supports two microphone modes:

- Follow the macOS default input device.
- Pin recording to a specific input device, such as an external USB microphone or Bluetooth microphone.

The selected device is written to `metadata.json` under `microphone_input`.

Related files:

- `AudioDeviceCatalog.swift`
- `MicCapture.swift`
- `Preferences.swift`
- `PreferencesView.swift`

### Local Retention Cleanup

Recorder1 can delete local recording folders after a successful Feishu Minutes upload.

Supported policies:

- Keep forever.
- Delete after 15 days.
- Delete after 30 days.

Cleanup only deletes folders whose `metadata.json` proves that upload completed and `minute_url` exists.

Related files:

- `RecordingRetentionPolicy.swift`
- `RecordingCleanup.swift`
- `Preferences.swift`

### Localization

Recorder1 adds Chinese and English UI strings.

Related files:

- `AppText.swift`
- `RecorderPanel.swift`
- `PreferencesView.swift`

## Local Data Layout

Upstream Recorder writes recordings under `~/Documents/Recordings`.

Recorder1 writes under:

```text
~/Documents/Recorder1/{YYYY-MM-DD_HHmm}-{meeting-title}/
```

Folder contents:

```text
desktop.caf
mic.caf
audio.m4a
metadata.json
upload.log
feishu_minutes.json
transcript.md
summary.md
```

`transcript.md` and `summary.md` are present only when Feishu returns usable content.

## Settings Added By Recorder1

Recorder1 adds these settings:

| Setting | Default | Purpose |
| --- | --- | --- |
| `lark-cli` binary path | auto-detect | Allows custom CLI location. |
| Auto upload after save | on | Uploads automatically after `audio.m4a` is saved. |
| Fetch notes after upload | on | Calls `vc +notes` after minute creation. |
| Copy minute URL after upload | off | Copies the Feishu Minute URL. |
| Open minute URL after upload | off | Opens the Feishu Minute URL. |
| Language | Chinese | Switches UI between Chinese and English. |
| Microphone input | system default | Supports external/Bluetooth microphone routing. |
| Local retention | keep forever | Optional cleanup after successful upload. |

## Signing And Permissions

Recorder1 keeps the app non-sandboxed and relies on macOS privacy prompts for:

- Microphone.
- System Audio Recording.
- Calendar.
- Notifications.
- Documents folder access.

Stable signing is strongly recommended for real testing. macOS ties privacy grants to the app identity, so repeated ad-hoc builds can cause repeated prompts or silent capture failures.

The installed app should include:

```text
com.apple.security.device.audio-input = true
```

Check with:

```bash
codesign --display --entitlements :- /Applications/Recorder1.app
```

## Verification Added By Recorder1

| Script | Purpose |
| --- | --- |
| `scripts/verify-mvp.sh` | Broad MVP smoke check. |
| `scripts/verify-upload-retry.sh` | Fake CLI test for failed upload and retry. |
| `scripts/verify-audio-capture-acceptance.sh` | Strict signed system-audio acceptance. |
| `scripts/analyze-latest-audio.sh` | Analyze latest local recording channels. |
| `scripts/verify-retention-cleanup.sh` | Check local cleanup policy behavior. |

## Current MVP Boundary

Recorder1 is suitable for local MVP testing when:

- macOS permissions are granted.
- The app is signed with a stable identity.
- `lark-cli` is installed and logged in.
- The Feishu/Lark tenant grants the required Drive, Minutes, and VC note permissions.
- The user's device route has been smoke-tested.

Recommended acceptance tests before critical use:

- One real meeting software smoke test.
- One Bluetooth output plus external microphone smoke test.
- One speaker or wired output smoke test.
- One 30-minute recording test.

## License

Recorder1 inherits the MIT license from upstream Recorder. The original license notice is preserved in the repository.
