# Meeting Capture

macOS menu-bar recorder for capturing meeting audio and sending the saved recording to Feishu Minutes through `lark-cli`.

## What It Does

- Runs as a menu-bar-only macOS app with no Dock icon.
- Records system output audio and microphone input at the same time.
- Saves raw channel files plus a mixed `audio.m4a`.
- Uploads `audio.m4a` to Feishu Drive with `lark-cli drive +upload`.
- Creates a Feishu Minute with `lark-cli minutes +upload`.
- Optionally waits for Feishu processing and fetches note artifacts with `lark-cli vc +notes`.
- Stores local metadata, upload logs, Feishu JSON, transcript, and summary next to the audio.
- Adds `audio_quality` to `metadata.json` after mixing so silent desktop or microphone channels are visible in local evidence.

## Local Output

Recordings are written under:

```text
~/Documents/MeetingCapture/{YYYY-MM-DD_HHmm}-{meeting-title}/
  desktop.caf
  mic.caf
  audio.m4a
  metadata.json
  upload.log
  feishu_minutes.json
  transcript.md
  summary.md
```

`transcript.md` and `summary.md` are created only when Feishu returns usable content through `vc +notes`.
`metadata.json` also includes an `audio_quality` block for new recordings, including duration, sample rate, channel count, left/right RMS, peak levels, and channel warnings.

## Requirements

- macOS 15 or later.
- Xcode 26 / Swift 6 toolchain.
- `lark-cli` installed and logged in as a user.
- Feishu user scopes:
  - `drive:file:upload`
  - `minutes:minutes.upload:write`
  - `vc:note:read`
  - `minutes:minutes:readonly`
  - `minutes:minutes.artifacts:read`
  - `minutes:minutes.transcript:export`

The app auto-detects `lark-cli` from `/opt/homebrew/bin/lark-cli`, common npm/global locations, and `PATH`. A custom binary path can be set in Settings.

## Build

```bash
./build.sh
open ./MeetingCapture.app
```

The build script defaults to ad-hoc signing so unattended builds do not hang on Keychain prompts. For stable macOS permissions across rebuilds, sign with a trusted certificate:

```bash
CODESIGN_IDENTITY="Apple Development: you@example.com" ./build.sh
```

If the certificate lives outside the login keychain, pass it explicitly:

```bash
CODESIGN_IDENTITY="Developer ID Application: Example" \
CODESIGN_KEYCHAIN="/path/to/signing.keychain-db" \
./build.sh
```

Stable signing matters because macOS ties microphone, system-audio capture, and calendar grants to the app's signing identity. Ad-hoc builds can require repeated permission approval and may cause Core Audio taps to deliver zero-filled system-audio buffers on macOS 26.

## MVP Self-Check

```bash
bash scripts/verify-mvp.sh
```

The self-check verifies the local macOS/Xcode/Swift environment, builds the app, confirms `LSUIElement=true`, checks that Gemini remnants are gone, validates Feishu CLI scopes, verifies failed-upload retry behavior with a fake CLI, inspects the latest local recording folder, and confirms the latest `audio.m4a` is playable stereo audio. It keeps real meeting, headset routing, and 30-minute recording checks as manual verification items.

After a real meeting or device-routing test, run the stricter channel check:

```bash
bash scripts/analyze-latest-audio.sh 1
```

For the 30-minute acceptance check:

```bash
bash scripts/analyze-latest-audio.sh 1800
```

The strict check requires both stereo channels to contain measurable audio. In the mixed file, left is desktop/system audio and right is microphone audio.

System-audio diagnostic:

```bash
MeetingCapture.app/Contents/MacOS/Recorder --diagnose-system-audio
```

This plays a short local sound and records the desktop channel through the same Core Audio tap used by the app. A passing result has `ok: true`; `rmsDB: -120` and `peakDB: -120` means macOS returned silent buffers.

## Feishu CLI Flow

```text
audio.m4a
  -> lark-cli drive +upload --file audio.m4a
  -> file_token
  -> lark-cli minutes +upload --file-token <file_token>
  -> minute_url
  -> minute_token
  -> lark-cli vc +notes --minute-tokens <minute_token>
```

Feishu Minutes generation is asynchronous, so the app retries `vc +notes` for a short period when the API returns `minute not ready`. Failures do not delete local recording files. Details are appended to `upload.log`, and the same `audio.m4a` can be retried from the app.
