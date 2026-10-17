# Audio capture and upload recovery validation

The 1.0.1 repair keeps the existing application identity and adds capture continuity checks, a shared acceptance gate, and persisted upload checkpoints.

## Automated regression checks

Run from the repository root on macOS:

```bash
swift build
./build.sh
codesign --verify --deep --strict .build/app-output.noindex/Recorder1.app
bash scripts/verify-audio-integrity.sh
bash scripts/verify-upload-retry.sh
bash scripts/verify-retention-cleanup.sh
```

`verify-audio-integrity.sh` generates synthetic stereo fixtures and checks sparse/silent system audio, capture failures, missing quality analysis, raw-track duration mismatch, and healthy audio. An optional local audio path can be supplied to evaluate a historical recording without uploading it.

`verify-upload-retry.sh` uses the fake CLI to verify bounded multipart retries, temporary service failures, authorization failures, inaccessible checkpoints, ambiguous creation outcomes, notes recovery, changed-file rejection, and termination of timed-out native CLI processes. It creates no remote files.

These checks run in the macOS CI job. Signing in CI is ad hoc; it does not certify the locally installed signing identity or native audio permissions.

## Native checks observed during this repair

- A signed build passed delayed audio playback, silence, pause/resume, and newly started playback processes over approximately two minutes.
- Output-device switching and 48 kHz / 44.1 kHz changes passed after microphone-engine recovery was added. The final system and microphone tracks differed by approximately 0.087 seconds over 139 seconds.
- The installed application passed system-audio capture and the real recording-library upload acceptance entry point.
- A synthetic 26.36 MB audio container passed live multipart upload, Minute creation, and transcript retrieval. Repeated execution reused both remote artifacts; creation commands each ran once. No meeting recording was uploaded during this check.
- The installed build retained its prior certificate and designated requirement. Local recordings and preferences were preserved.

Raw measurements, logs, private recording details, and cloud identifiers are retained locally outside version control.

## Reproducing native checks

Build using the existing local signing identity, then run the signed app executable:

```bash
.build/app-output.noindex/Recorder1.app/Contents/MacOS/Recorder --diagnose-continuity --diagnose-duration 120
.build/app-output.noindex/Recorder1.app/Contents/MacOS/Recorder --diagnose-system-audio
.build/app-output.noindex/Recorder1.app/Contents/MacOS/Recorder --diagnose-upload-gate --diagnose-folder /path/to/local/recording
```

The continuity probe plays synthetic test tones and captures the selected microphone. Device and sample-rate changes must be exercised on the test machine. The upload-gate probe expects a degraded local recording and confirms that upload is blocked before CLI execution.

Live upload is an explicit, optional check using `scripts/verify-live-upload.swift` compiled with the uploader sources. It requires `--live-upload` and a folder containing synthetic `audio.m4a`; it creates a Drive file and a Minute in the authenticated user's account. It is not part of CI.

## Remaining validation

Thirty-minute recordings, Bluetooth devices, and calls in each meeting client have not been exercised. Automated UI clicking timed out, so this record does not claim full GUI acceptance. Those gaps do not change the observed native capture and uploader results above.
