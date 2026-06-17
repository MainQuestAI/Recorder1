# Recorder1 Public Verification Notes

This document records public-safe verification coverage for Recorder1. It intentionally avoids real tenant domains, local user paths, real Feishu tokens, and private recording content.

## Environment Class

Recorder1 is intended for:

- macOS 15 or later,
- Xcode / Swift toolchains that support Swift Package Manager,
- a signed macOS app bundle for stable TCC permission behavior,
- a user-installed and user-authenticated `lark-cli` for Feishu/Lark upload.

Exact local machine details are omitted from the public repository because they are not required to reproduce the project.

## Build Verification

Expected local commands:

```bash
swift build
./build.sh
codesign --verify --deep --strict Recorder1.app
```

Expected result:

- Swift package builds.
- `Recorder1.app` is assembled.
- `LSUIElement=true`, so the app runs as a menu-bar utility.
- The app bundle passes code-signing verification.

## Fake Upload Retry Verification

Command:

```bash
bash scripts/verify-upload-retry.sh
```

Expected result:

- A fake `lark-cli` is used.
- The first upload can fail without deleting `audio.m4a`.
- Retry upload reuses the existing `audio.m4a`.
- `metadata.json` is updated with fake file and minute values.
- `upload.log` records the failure and retry flow.

Representative fake values:

```json
{
  "file_token": "fake-file-token",
  "minute_url": "https://example.feishu.cn/minutes/fake-minute-token",
  "minute_token": "fake-minute-token"
}
```

These values are fixtures, not real tenant data.

## Retention Cleanup Verification

Command:

```bash
bash scripts/verify-retention-cleanup.sh
```

Expected result:

- Uploaded recordings older than the configured retention period are deleted.
- Recordings without `upload_status=uploaded` are not deleted.
- Recordings without `minute_url` are not deleted.
- Keep-forever policy deletes nothing.

## Feishu CLI Response Shape

Recorder1 expects `lark-cli` to print JSON that contains these fields after any human-readable progress lines.

Drive upload:

```json
{
  "ok": true,
  "identity": "user",
  "data": {
    "file_name": "sample-audio.m4a",
    "file_token": "<file_token>",
    "size": 123456,
    "url": "https://example.feishu.cn/file/<file_token>",
    "version": "<version>"
  }
}
```

Minutes upload:

```json
{
  "ok": true,
  "identity": "user",
  "data": {
    "minute_url": "https://<tenant>.feishu.cn/minutes/<minute_token>"
  }
}
```

Notes pending:

```json
{
  "ok": true,
  "identity": "user",
  "data": {
    "notes": [
      {
        "error": "minute not ready , try later",
        "minute_token": "<minute_token>"
      }
    ]
  },
  "meta": {
    "count": 1
  }
}
```

Notes ready:

```json
{
  "ok": true,
  "identity": "user",
  "data": {
    "notes": [
      {
        "artifacts": {
          "transcript_file": "minutes/<minute_token>/transcript.txt"
        },
        "minute_token": "<minute_token>",
        "title": "sample-audio"
      }
    ]
  },
  "meta": {
    "count": 1
  }
}
```

## Audio Verification

Latest recording analysis:

```bash
bash scripts/analyze-latest-audio.sh 1
```

Long recording analysis:

```bash
bash scripts/analyze-latest-audio.sh 1800
```

Expected result:

- `audio.m4a` is stereo.
- Left channel contains measurable system audio.
- Right channel contains measurable microphone audio.
- The script fails when a required channel is silent.

## System Audio Diagnostic

Command:

```bash
/Applications/Recorder1.app/Contents/MacOS/Recorder \
  --diagnose-system-audio-matrix \
  --diagnose-output /tmp/recorder1-system-audio-matrix.json
```

The diagnostic records:

- tap kind,
- output device role,
- output device UID and name,
- callback count,
- frame count,
- RMS and peak levels,
- whether the probe was usable.

The output file can contain local device names and should be reviewed before attaching it to public issues.

## Manual Verification

CI cannot grant TCC permissions or capture real system audio. Before production use, manually test:

- a real meeting app,
- Bluetooth output plus external microphone input,
- speaker or wired output,
- a 30-minute continuous recording.
