# Recorder1

Recorder1 is a native macOS menu-bar app for capturing meeting audio and sending the saved recording to Feishu Minutes through `lark-cli`.

## 中文导览

- 中文完整说明：[README.zh-CN.md](README.zh-CN.md)
- 快速了解：Recorder1 是一个 macOS 菜单栏会议录音工具，录制系统声音和麦克风，并自动上传到飞书妙记。
- 本地安装：查看 [Build](#build) 和 [Install Locally](#install-locally)。
- 首次授权：查看 [First Run Permissions](#first-run-permissions)。
- 飞书配置：查看 [Feishu CLI Flow](#feishu-cli-flow)。
- 录音验收：查看 [Verification](#verification)。
- 上游改造说明：查看 [docs/upstream-recorder-migration.md](docs/upstream-recorder-migration.md)。

It records two sources at the same time:

- **System audio -> left channel**: the remote participants, media playback, or meeting audio you hear.
- **Microphone audio -> right channel**: your local microphone, including external USB/Bluetooth microphones.

The app keeps the raw channel files, creates a stereo `audio.m4a`, uploads it to Feishu Drive, creates a Feishu Minute, and stores local metadata and upload logs next to the recording.

## Status

Recorder1 is currently an MVP. The core local flow has been validated on macOS with Bluetooth output and an external microphone. Real meeting software, long recordings, and more audio routes should still be smoke-tested before using it as a critical recorder.

## Relationship To Upstream Recorder

Recorder1 is derived from [tobi/recorder](https://github.com/tobi/recorder), a Swift / SwiftUI macOS menu-bar recorder. The upstream project provides the core local recording model: menu-bar UI, calendar-aware recording, system audio capture, microphone capture, dual raw CAF files, and stereo `audio.m4a` output.

Recorder1 keeps that local recording foundation and changes the post-recording workflow from Gemini transcription to Feishu Minutes upload through `lark-cli`.

See [docs/upstream-recorder-migration.md](docs/upstream-recorder-migration.md) for the detailed adaptation notes.

## Features

- One-click menu-bar recording with no Dock icon.
- Simultaneous system audio and microphone capture.
- Stereo output where left is system audio and right is microphone audio.
- Optional microphone device selection for external USB/Bluetooth mics.
- Calendar-aware meeting list and meeting-based folder names.
- Feishu upload flow:
  - `lark-cli drive +upload`
  - `lark-cli minutes +upload`
  - optional `lark-cli vc +notes`
- Retry upload without re-recording.
- Local `metadata.json`, `upload.log`, Feishu JSON, transcript, and summary files.
- Audio-quality analysis after mixing.
- Degraded-capture guard that can block automatic upload when only the microphone channel was captured.
- Output-route change logging and system-audio tap rebuild.
- Chinese and English UI.
- Optional local cleanup after successful upload: keep forever, delete after 15 days, or delete after 30 days.

## Local Output

Recordings are written under:

```text
~/Documents/Recorder1/{YYYY-MM-DD_HHmm}-{meeting-title}/
  desktop.caf
  mic.caf
  audio.m4a
  metadata.json
  upload.log
  feishu_minutes.json
  transcript.md
  summary.md
```

File roles:

| File | Purpose |
| --- | --- |
| `desktop.caf` | Raw mono system audio, flushed during recording. |
| `mic.caf` | Raw mono microphone audio, flushed during recording. |
| `audio.m4a` | Final stereo AAC mix. Left = system audio, right = microphone. |
| `metadata.json` | Meeting metadata, local paths, upload status, Feishu tokens, audio quality, capture integrity, and selected microphone device. |
| `upload.log` | Local upload and capture log. |
| `feishu_minutes.json` | Combined Feishu Drive, Minutes, and notes API output. |
| `transcript.md` | Transcript content when Feishu returns it. |
| `summary.md` | Summary content when Feishu returns it. |

## Requirements

- macOS 15 or later.
- Xcode / Swift toolchain capable of building Swift Package Manager projects.
- `lark-cli` installed and logged in as a Feishu/Lark user.
- Feishu/Lark permissions for the user running `lark-cli`:
  - `drive:file:upload`
  - `minutes:minutes.upload:write`
  - `vc:note:read`
  - `minutes:minutes:readonly`
  - `minutes:minutes.artifacts:read`
  - `minutes:minutes.transcript:export`

The app auto-detects `lark-cli` from common Homebrew/npm locations and `PATH`. A custom binary path can be set in Settings.

## Build

```bash
./build.sh
open ./Recorder1.app
```

The build script defaults to ad-hoc signing so unattended local builds do not hang on Keychain prompts.

For stable macOS permissions across rebuilds, sign with a trusted certificate:

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com" ./build.sh
```

If the certificate lives outside the login keychain, pass it explicitly:

```bash
CODESIGN_IDENTITY="Developer ID Application: Example" \
CODESIGN_KEYCHAIN="/path/to/signing.keychain-db" \
./build.sh
```

Stable signing matters because macOS ties microphone, system-audio capture, calendar, and file-access grants to the app's signing identity. Ad-hoc builds can require repeated permission approval and can produce zero-filled system-audio buffers on some macOS 26 setups.

For strict system-audio acceptance builds, use:

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com" \
bash scripts/build-for-audio-capture-acceptance.sh
```

The helper refuses ad-hoc signing and writes `signing-report.txt`.

## Install Locally

After building, copy the signed app into Applications:

```bash
rm -rf /Applications/Recorder1.app
ditto --rsrc --extattr Recorder1.app /Applications/Recorder1.app
open /Applications/Recorder1.app
```

The app is a menu-bar utility. Look for the microphone icon in the macOS menu bar.

## First Run Permissions

Recorder1 asks macOS for these permissions:

| Permission | Why it is needed |
| --- | --- |
| Microphone | Capture your local microphone channel. |
| System Audio Recording | Capture meeting/system output audio through Core Audio taps. |
| Calendars | Show nearby meetings and name recordings after meetings. |
| Notifications | Show meeting-end reminders. |
| Documents folder | Save recordings under `~/Documents/Recorder1`. |

If permissions appear stuck after changing bundle IDs or signing identities, quit the app, reset the app's permissions, reinstall, and open it again:

```bash
tccutil reset All com.dingcheng.Recorder1
open /Applications/Recorder1.app
```

## Settings

Recorder1 includes settings for:

- `lark-cli` binary path.
- Auto upload after save.
- Fetch notes after upload.
- Copy minute URL after upload.
- Open minute URL after upload.
- UI language: Chinese or English.
- Microphone input: follow macOS default input, or choose a specific external/Bluetooth device.
- Local retention after upload: keep forever, delete after 15 days, or delete after 30 days.
- Silence auto-stop threshold and timeout.

## Feishu CLI Flow

```text
audio.m4a
  -> lark-cli drive +upload --as user --file audio.m4a --json
  -> file_token
  -> lark-cli minutes +upload --as user --file-token <file_token> --json
  -> minute_url
  -> minute_token
  -> lark-cli vc +notes --as user --minute-tokens <minute_token> --overwrite --json
```

Feishu Minutes generation is asynchronous. Recorder1 retries `vc +notes` for a short period when the CLI reports that the minute is not ready.

Upload failures do not delete local recordings. The app records the error in `upload.log`, keeps `audio.m4a`, and lets the user retry the upload.

## Verification

Run the MVP self-check:

```bash
bash scripts/verify-mvp.sh
```

The self-check verifies the local macOS/Xcode/Swift environment, builds the app, confirms `LSUIElement=true`, validates the Feishu CLI surface, verifies failed-upload retry behavior with a fake CLI, inspects the latest local recording folder, and confirms that the latest `audio.m4a` is playable stereo audio.

After a real meeting or device-routing test, inspect the latest recording:

```bash
bash scripts/analyze-latest-audio.sh 1
```

For a 30-minute acceptance check:

```bash
bash scripts/analyze-latest-audio.sh 1800
```

The strict channel check expects both stereo channels to contain measurable audio. In the mixed file, left is system audio and right is microphone audio.

System-audio matrix diagnostic:

```bash
Recorder1.app/Contents/MacOS/Recorder \
  --diagnose-system-audio-matrix \
  --diagnose-output /tmp/recorder1-system-audio-matrix.json
```

Strict local audio-capture acceptance:

```bash
bash scripts/verify-audio-capture-acceptance.sh
```

This fails if the app is ad-hoc signed, if no default-output probe succeeds, if `desktop.caf` is silent, or if the mixed `audio.m4a` left channel is silent.

## Architecture

```text
MenuBarExtra / RecorderPanel
        |
        v
RecorderModel
  |         |
  |         +--> MicCapture -> mic.caf
  |
  +------------> SystemAudioTap -> desktop.caf
                    |
                    v
             StereoMixer -> audio.m4a
                    |
                    v
          AudioQualityAnalyzer
                    |
                    v
             FeishuCLIUploader
                    |
                    v
  metadata.json / upload.log / feishu_minutes.json / transcript.md / summary.md
```

Key source files:

| File | Role |
| --- | --- |
| `RecorderApp.swift` | Menu-bar app entry point and diagnostic command routing. |
| `RecorderModel.swift` | Main state machine for recording, mixing, upload, retry, and cleanup. |
| `RecorderPanel.swift` | Menu-bar UI. |
| `SystemAudioTap.swift` | Core Audio system-output capture, fallback, route-change handling, and metadata. |
| `MicCapture.swift` | AVAudioEngine microphone capture and input-device selection. |
| `StereoMixer.swift` | Aligns raw channels and writes the stereo AAC output. |
| `FeishuCLIUploader.swift` | Runs the Feishu `lark-cli` upload flow. |
| `FeishuMinutesParser.swift` | Parses CLI JSON and extracts Feishu Minutes artifacts. |
| `UploadStatusStore.swift` | Writes metadata and upload logs. |
| `RecordingCleanup.swift` | Deletes uploaded local recordings after the configured retention window. |

## Troubleshooting

### No microphone permission prompt appears

Check that the installed app is signed with the expected identity and includes audio input entitlement:

```bash
codesign -dv --verbose=4 /Applications/Recorder1.app
codesign --display --entitlements :- /Applications/Recorder1.app
```

Then reset permissions and reopen the app:

```bash
tccutil reset All com.dingcheng.Recorder1
open /Applications/Recorder1.app
```

### System audio is silent

Run the matrix diagnostic under the installed app identity:

```bash
/Applications/Recorder1.app/Contents/MacOS/Recorder \
  --diagnose-system-audio-matrix \
  --diagnose-output /tmp/recorder1-system-audio-matrix.json
```

On some macOS 26 systems, global and device-bound Core Audio taps can return silent buffers while process mixdown works. Recorder1 records the selected tap mode in `metadata.json`.

### Upload fails

Recorder1 keeps local recordings after upload failure. Check:

```text
upload.log
metadata.json
```

Then use Retry Upload from the menu-bar panel after fixing `lark-cli` login, path, or permissions.

## Documentation

- [Upstream Recorder to Recorder1 migration](docs/upstream-recorder-migration.md)
- [Development brief](docs/development-brief-2026-06-17.md)
- [Verification notes](docs/verification-2026-06-16.md)
- [Research notes](docs/research-notes.md)

## Privacy Notes

Recorder1 stores recordings and metadata locally under `~/Documents/Recorder1`. If auto upload is enabled, `audio.m4a` is uploaded through the user's local `lark-cli` session. The app does not embed Feishu credentials or API tokens.

`metadata.json` and `upload.log` can contain meeting titles, local file paths, Feishu file tokens, and minute URLs. Treat recording folders as private data.

## License

MIT. See [LICENSE](LICENSE).

Recorder1 is derived from [tobi/recorder](https://github.com/tobi/recorder). See [NOTICE.md](NOTICE.md) for attribution and modification notes.
