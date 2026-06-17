# Recorder1 Release Validation Notes

This document summarizes the public-safe validation status for Recorder1 before open-source publication.

## Scope

Recorder1 is a macOS menu-bar recorder that captures:

- system output audio,
- microphone input audio,
- a stereo `audio.m4a` mix where system audio is left and microphone audio is right.

After recording, it can upload `audio.m4a` through the user's local `lark-cli` session, create a Feishu Minute, fetch available note artifacts, and store local metadata and logs.

## Validated MVP Capabilities

- App launches as a menu-bar utility with no Dock icon.
- Start / stop recording flow works.
- System audio and microphone are written to separate raw CAF files.
- Stereo `audio.m4a` is generated after stop.
- `metadata.json` and `upload.log` are written next to the recording.
- Failed uploads preserve local recordings.
- Retry upload reuses the existing `audio.m4a`.
- Feishu Drive upload response parsing extracts `file_token`.
- Feishu Minutes upload response parsing extracts `minute_url`.
- `minute_token` is extracted from the Feishu Minutes URL.
- Optional notes fetching can write `feishu_minutes.json`, `transcript.md`, and `summary.md` when artifacts are available.
- Capture integrity analysis can block automatic upload when system audio is silent and microphone audio is present.
- The app can record with Bluetooth output and an external microphone route.

## System Audio Notes

Recorder1 includes multiple system-audio capture modes and diagnostics:

- global Core Audio tap,
- device-bound Core Audio tap,
- process mixdown fallback,
- route-change logging,
- tap rebuild on output device changes.

On some macOS versions and routes, a Core Audio tap can report callbacks and frame counts while returning silent samples. Recorder1 records capture metadata and can fall back to another tap mode when needed.

## Public Test Commands

Build:

```bash
swift build
./build.sh
```

Upload retry test with a fake CLI:

```bash
bash scripts/verify-upload-retry.sh
```

Retention cleanup test:

```bash
bash scripts/verify-retention-cleanup.sh
```

MVP smoke test:

```bash
bash scripts/verify-mvp.sh
```

Latest recording audio analysis:

```bash
bash scripts/analyze-latest-audio.sh 1
```

30-minute recording analysis:

```bash
bash scripts/analyze-latest-audio.sh 1800
```

## CI Boundary

CI intentionally does not:

- request macOS TCC permissions,
- perform real system audio capture,
- depend on a logged-in `lark-cli`,
- upload to a real Feishu tenant.

CI covers buildability, app bundle assembly, code signing verification, fake upload retry, and retention cleanup logic.

## Manual Verification Still Recommended

Before relying on Recorder1 for important meetings, run:

- one real meeting software recording,
- one Bluetooth output plus external microphone recording,
- one wired or speaker output recording,
- one 30-minute continuous recording.

## Privacy Reminder

Recording folders can contain meeting audio, meeting titles, local paths, Feishu file tokens, Feishu Minute URLs, transcripts, summaries, and upload logs. Do not attach recording folders to public issues without redaction.
