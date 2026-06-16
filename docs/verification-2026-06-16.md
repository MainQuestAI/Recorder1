# Meeting Capture MVP Verification - 2026-06-16

## Environment

- macOS: 26.5.1
- Xcode: 26.5
- Swift: 6.3.2
- Build commands:
  - `swift build` passed
  - `./build.sh` passed
- App bundle:
  - `MeetingCapture.app`
  - `CFBundleIdentifier = com.dingcheng.MeetingCapture`
  - `LSUIElement = true`
- Signing:
  - `build.sh` now defaults to ad-hoc signing so unattended builds do not hang on Keychain prompts.
  - Stable signing is still supported through `CODESIGN_IDENTITY`; `CODESIGN_KEYCHAIN` can point to a specific keychain.
  - The existing local certificate `Meeting Capture Local Code Signing` currently waits for Keychain/user trust confirmation when used unattended, so it is not used automatically.
  - Avoid `tccutil reset` during normal MVP verification; permission resets should only be used for first-run prompt tests.
- Runtime:
  - `MeetingCapture.app/Contents/MacOS/Recorder` launched and stayed running.
  - TCC permission rows were later confirmed for `com.dingcheng.MeetingCapture`:
    - `kTCCServiceCalendar = 2`
    - `kTCCServiceMicrophone = 2`
    - `kTCCServiceAudioCapture = 2`

## MVP Self-Check

- Script: `scripts/verify-mvp.sh`
- Stable command: `bash scripts/verify-mvp.sh`
- Latest run result after the dark UI and device-bound Core Audio tap changes:
  - 26 passed
  - 3 warnings
  - 0 failed
- Covered checks:
  - macOS/Xcode/Swift tools are present.
  - macOS 26.5.1 satisfies `LSMinimumSystemVersion = 15.0`.
  - `swift build` passed.
  - `./build.sh` produced `MeetingCapture.app`.
  - `LSUIElement = true`, so the app is menu-bar-only.
  - Code signing verification passed.
  - Microphone, system audio capture, and calendar permissions are allowed.
  - Gemini remnants were not found.
  - `lark-cli` resolved to `/Users/dingcheng/.npm-global/bin/lark-cli`.
  - Required Feishu scopes are available.
  - Failed upload preserves `audio.m4a`, writes `failed` metadata, and retry succeeds with the same relative `audio.m4a` path.
  - Latest local recording folder has `metadata.json`, `upload.log`, and `audio.m4a`.
  - Latest `audio.m4a` is playable stereo AAC and can be inspected for per-channel signal levels.
  - New app builds include post-mix `audio_quality` metadata for new recordings.

## MainQuest Dark UI Update

- `RecorderPanel.swift` was restyled using MainQuest-style dark glass tokens:
  - black page background `#030305`
  - low-opacity elevated/surface fills
  - subtle white borders
  - white/gray typography
  - green success, orange warning, blue info, red recording/destructive states
- The menu-bar panel remains functionally unchanged:
  - Record / Record Meeting
  - Pause / Resume
  - Stop
  - Discard
  - Upload status, Open Minute, Copy URL, Retry Upload
  - Meetings, recent recordings, settings, recordings folder, quit
- `swift build -c release` passed after the UI changes.

## Menu-Bar UI Probe

- The menu-bar status item was accessible through macOS accessibility automation.
- A first automated Record click, performed before microphone permission was approved, produced a partial folder:
  - `~/Documents/MeetingCapture/2026-06-16_2300/desktop.caf`
  - `metadata.json`
  - `upload.log`
- That exposed a startup edge case: capture could fail after creating a recording folder, leaving metadata at `recording`.
- The code was updated to wait for microphone permission before creating a recording session and to mark startup failures as `capture_failed` in `metadata.json` / `upload.log`.
- Microphone permission is now requested only after the user clicks Record, and the app is activated before the request so the macOS prompt is visible.
- A follow-up automated Record click after this fix did not create a new partial recording folder while microphone permission remained unapproved.

## App Recording + Upload Probe

- Local folder: `~/Documents/MeetingCapture/2026-06-16_2308`
- Files confirmed:
  - `desktop.caf`
  - `mic.caf`
  - `audio.m4a`
  - `metadata.json`
  - `upload.log`
  - `feishu_minutes.json`
  - `transcript.md`
  - `minutes/obcn954m592edpbzd2czuge5/transcript.txt`
- `audio.m4a` confirmed by `afinfo`:
  - AAC m4a
  - 2 channels
  - 48 kHz
  - estimated duration `4.574729` seconds
- `audio.m4a` channel analysis:
  - duration `4.575` seconds
  - encoded channels `2`
  - processing channels `2`
  - left/desktop RMS `-120.0 dB`
  - right/mic RMS `-31.7 dB`
  - conclusion: this short probe proves playable stereo output and active microphone capture; it does not prove active system/remote audio capture because the desktop channel is silent.
- Upload metadata:
  - `upload_status = uploaded`
  - `file_token = LBsabUsBso9306x9069cJ7ZOn4b`
  - `minute_url = https://l2juegzht0.feishu.cn/minutes/obcn954m592edpbzd2czuge5`
  - `minute_token = obcn954m592edpbzd2czuge5`
- `vc +notes` behavior:
  - attempt 1 returned `minute not ready , try later`
  - attempt 2 returned `artifacts.transcript_file`
  - `transcript.md` was written locally

## Local System Playback Probe

- Local folder: `~/Documents/MeetingCapture/2026-06-16_2327`
- Test setup:
  - Auto upload was temporarily disabled for this local audio-only test.
  - Recording was started from the menu-bar app.
  - macOS `say` played a short phrase through the default output device.
  - Recording was stopped from the menu-bar app.
  - Auto upload was restored to `true` afterward, and the app was relaunched from the latest build.
- Files confirmed:
  - `desktop.caf`
  - `mic.caf`
  - `audio.m4a`
  - `metadata.json`
  - `upload.log`
- `audio.m4a` confirmed by `afinfo`:
  - AAC m4a
  - 2 channels
  - 48 kHz
  - estimated duration `109.380646` seconds
- Strict channel analysis:
  - left/desktop RMS `-117.0 dB`
  - right/mic RMS `-28.6 dB`
  - conclusion: microphone channel was active, but desktop/system channel remained effectively silent. This does not satisfy the remote/system audio requirement.
- Follow-up code change:
  - Added `AudioQualityAnalyzer.swift`.
  - New recordings now write an `audio_quality` block to `metadata.json`.
  - New recordings append audio-quality warnings to `upload.log` when desktop/system or microphone channels look silent.

## System-Audio Zero-Buffer Diagnosis

- App-level diagnostic command:

```bash
MeetingCapture.app/Contents/MacOS/Recorder --diagnose-system-audio --diagnose-output /tmp/meeting-capture-system-audio.json
```

- Result with the global Core Audio tap:

```json
{
  "frameCount": 260096,
  "ok": false,
  "peakDB": -120,
  "rmsDB": -120,
  "sampleRate": 48000
}
```

- Follow-up change:
  - `SystemAudioTap.swift` now uses a device-bound tap for the current default system output device:
    - `CATapDescription(__excludingProcesses: [], andDeviceUID: outputUID, withStream: 0)`
  - On macOS 26, `isProcessRestoreEnabled` is enabled.
  - Tap drift compensation quality is explicitly set on the aggregate tap list.

- Result after switching to the device-bound tap:

```json
{
  "frameCount": 259584,
  "ok": false,
  "peakDB": -120,
  "rmsDB": -120,
  "sampleRate": 48000
}
```

- Interpretation:
  - Core Audio callbacks are active and the tap writes frames.
  - The delivered samples are all zero, so the desktop/system channel is still blocked before real PCM reaches the app.
  - Current evidence points to macOS TCC/signing trust behavior on macOS 26, because ad-hoc or untrusted-signature Core Audio taps can be authorized in Settings while still receiving zero-filled buffers.
  - ScreenCaptureKit fallback was not added because this machine has no screen-recording TCC grant for `com.dingcheng.MeetingCapture`, and adding it would trigger a new permission prompt.

## Feishu CLI

- `lark-cli` version: 1.0.54
- User identity: ready
- Required scopes verified:
  - `drive:file:upload`
  - `minutes:minutes.upload:write`
  - `vc:note:read`
  - `minutes:minutes:readonly`
  - `minutes:minutes.artifacts:read`
  - `minutes:minutes.transcript:export`

## Real Feishu API Results

### drive +upload

Command shape:

```bash
lark-cli drive +upload --as user --file <audio.m4a> --json
```

Observed output shape:

```json
{
  "ok": true,
  "identity": "user",
  "data": {
    "file_name": "meeting-capture-stereo-65s-20260616.m4a",
    "file_token": "Nx7jbm8Euohy2hxVkWCcJRdyn4f",
    "size": 913224,
    "url": "https://my.feishu.cn/file/Nx7jbm8Euohy2hxVkWCcJRdyn4f",
    "version": "7652006816695503855"
  }
}
```

Note: the CLI prints a human-readable progress line before the JSON.

### minutes +upload

Command shape:

```bash
lark-cli minutes +upload --as user --file-token <file_token> --json
```

Observed output shape:

```json
{
  "ok": true,
  "identity": "user",
  "data": {
    "minute_url": "https://l2juegzht0.feishu.cn/minutes/obcn94fq3q44171159o7oe3m"
  }
}
```

### vc +notes

Command shape:

```bash
lark-cli vc +notes --as user --minute-tokens <minute_token> --overwrite --json
```

Observed pending output:

```json
{
  "ok": true,
  "identity": "user",
  "data": {
    "notes": [
      {
        "error": "minute not ready , try later",
        "minute_token": "obcn94fq3q44171159o7oe3m"
      }
    ]
  },
  "meta": {
    "count": 1
  }
}
```

Observed ready output:

```json
{
  "ok": true,
  "identity": "user",
  "data": {
    "notes": [
      {
        "artifacts": {
          "transcript_file": "minutes/obcn94fq3q44171159o7oe3m/transcript.txt"
        },
        "minute_token": "obcn94fq3q44171159o7oe3m",
        "title": "meeting-capture-stereo-65s-20260616"
      }
    ]
  },
  "meta": {
    "count": 1
  }
}
```

Note: the CLI prints progress lines before the JSON.

## Verified Audio File

- File: `meeting-capture-stereo-65s-20260616.m4a`
- Format: AAC m4a
- Channels: stereo
- Duration: 65 seconds
- Feishu Minutes accepted the file and reported duration `64993` ms.

## Remaining Manual Verification

- Confirm a real meeting recording includes both remote meeting audio and local microphone audio.
  - Evidence command after each test: `bash scripts/analyze-latest-audio.sh 1`
  - Expected result: both left/desktop and right/mic RMS are above the configured threshold.
- Test Zoom, Feishu Meeting, Tencent Meeting, Teams, and Google Meet.
- Test AirPods, wired headset, and speaker output routing.
- Run a continuous 30-minute recording and play back `audio.m4a`.
  - Evidence command: `bash scripts/analyze-latest-audio.sh 1800`
