# Recorder

A small, native macOS **menu-bar app** that records your meetings and voice notes with one
click. It captures **two audio sources at once** and mixes them into a single stereo file —
so you can always tell who was on the call from who was in the room:

- **Desktop / system audio → Left channel** (the people you hear through your speakers)
- **Your microphone → Right channel** (you, and anyone physically with you)

Optionally, it then **transcribes and diarizes** the recording with Google Gemini, using the
stereo layout (left = remote, right = local) plus the meeting's calendar attendees to sharpen
the speaker labels.

Pure Swift / SwiftUI. No Dock icon, no external runtime dependencies, no ffmpeg — just a
single ad-hoc-signed `.app`.

---

## Why two channels?

Most recorders give you one muddy mono mix. By hard-panning **system audio left** and **your
mic right**, the channels stay cleanly separated:

- You can mute/solo either side in any audio editor.
- Diarization gets a massive head start — "left channel" is almost always the remote
  participants and "right channel" is almost always you.
- It survives crashes: each source is written to its **own raw file continuously**, and the
  stereo mix is produced only when you hit Save. A crash loses at most a fraction of a second.

---

## Features

- **One-click Record / Pause / Save / Trash** from a compact menu-bar panel.
- **Live level meters** for both channels (desktop L, mic R).
- **Calendar-aware**: the panel lists nearby meetings (last couple, the current one, and the
  next couple). Click one to start a recording named after it; the in-progress meeting is
  highlighted.
- **Automatic transcription** via Gemini when a recording is saved (toggleable). Produces a
  timestamped, diarized Markdown transcript with a separate "speaker identity guesses" section
  — real names are never forced into the transcript body.
- **Recordings library**: browse and re-open past recordings and their transcripts right from
  the panel, even after a relaunch.
- **Silence auto-stop**: ends a recording after a configurable period of two-channel silence
  (default 5 min), so a forgotten recording doesn't run forever.
- **Meeting-end notification** with a "Stop Recording" action when a meeting's scheduled end
  passes while you're still recording.
- **System-audio watchdog** that rebuilds the Core Audio tap if macOS's known process-tap
  regression makes it go silent mid-recording.

---

## How it works (architecture)

The design is documented in depth in [`docs/research-notes.md`](docs/research-notes.md). The
short version:

| Concern | Approach |
| --- | --- |
| **Desktop audio** | Core Audio **process tap** (`CATapDescription` + `AudioHardwareCreateProcessTap`) wrapped in a tap-only private aggregate device, driven by an IOProc. Needs only the *Audio Recording* permission — **not** Screen Recording. |
| **Microphone** | A separate `AVAudioEngine` input tap. Format is read from the device (never hardcoded — Bluetooth mics report odd sample rates). |
| **Two captures, merged on stop** | Each source streams to its own raw `.caf`. They're aligned (via first-buffer host-time skew), resampled to a common 48 kHz, interleaved (L=desktop, R=mic), and encoded to AAC `.m4a` only on Save. The raw files are kept. |
| **Realtime safety** | The IOProc runs on a hard-realtime thread (~10 ms deadline). It does **memcpy only**, into a lock-free single-producer/single-consumer [ring buffer](Sources/Recorder/FloatRingBuffer.swift); a background thread drains the ring to disk. No `malloc`, no file I/O on the audio thread — which is what eliminates the buffer-boundary clicks a naive `write()`-in-the-callback design produces. |
| **Transcription** | Gemini Files API (resumable upload → poll until `ACTIVE` → `generateContent`) on a Flash model with `thinkingBudget = 0`. |

---

## Requirements

- **macOS 15+** (the realtime ring buffer uses the `Synchronization` module's `Atomic`).
- **Xcode 26 / Swift 6.x** to build. Developed and tested on macOS 26.3, Apple Silicon.
- A **Google Gemini API key** if you want transcription (optional; recording works without it).

---

## Build & run

```sh
./build.sh           # swift build -c release, then assemble + ad-hoc-sign Recorder.app
open ./Recorder.app  # launches as a menu-bar item (no Dock icon)
```

You can also open `Package.swift` in Xcode and run from there.

The app is **non-sandboxed** and **ad-hoc signed**. If you rebuild with a different signature,
macOS may re-issue the permission prompts (TCC tracks the code signature).

---

## Permissions

Granted on first use via standard system prompts (declared in `Info.plist`):

- **Microphone** — to capture your voice.
- **System Audio Recording** — desktop audio via the Core Audio process tap. This is the
  *audio* permission, **not** Screen Recording; you'll see the purple privacy dot while
  recording.
- **Calendars (full access)** — to list nearby meetings and name recordings after them.
- **Notifications** — for the "meeting ended — still recording" alert.

---

## Transcription setup

1. Get a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey).
2. Open the panel → **Settings** → paste the key under **API key**. It's stored in the macOS
   **Keychain** (never written to disk in plaintext, never committed).
3. (Optional) Set **your name** under Identity — it's passed to the model as a hint that the
   right-channel voice is usually you. There is no baked-in default; leave it blank to stay
   anonymous.
4. Toggle **auto-transcribe** on/off. With it off, recordings still save and you can transcribe
   later.

The transcript is written next to the audio as `transcript.md`.

---

## File layout

Recordings land in `~/Documents/Recordings/{YYYY-M-D}-{HHMM}[-{meeting}]/`:

```
desktop.caf    raw mono system audio  (flushed continuously while recording)
mic.caf        raw mono microphone    (flushed continuously while recording)
audio.m4a      stereo AAC mix — desktop = L, mic = R (produced on Save; raw files kept)
transcript.md  diarized Markdown transcript (if transcription ran)
```

CAF (not WAV) is used for the raw files so long meetings don't hit the 4 GB WAV ceiling.

---

## Project structure

```
Sources/Recorder/
  RecorderApp.swift          MenuBarExtra scene + app delegate adaptor
  AppDelegate.swift          .accessory activation policy; notification setup
  RecorderModel.swift        @Observable state machine; owns captures, monitors, meetings
  Preferences.swift          typed UserDefaults wrapper (name, silence, auto-transcribe)
  Keychain.swift             Gemini API key storage in the login Keychain
  SystemAudioTap.swift       process tap + aggregate + IOProc → desktop.caf; watchdog
  FloatRingBuffer.swift      lock-free SPSC ring buffer (realtime-safe capture path)
  MicCapture.swift           AVAudioEngine input tap → mic.caf
  AudioMonitors.swift        RMS → dBFS metering + dual-channel silence monitor
  StereoMixer.swift          align + resample + interleave (L=desktop, R=mic) + AAC → m4a
  GeminiTranscriber.swift    Gemini Files API upload + diarization prompt + generateContent
  CalendarAccess.swift       EventKit: full-access auth, meetings-around-now
  NotificationManager.swift  meeting-end alert + "Stop Recording" action
  RecordingsLibrary.swift    reads ~/Documents/Recordings for the past-recordings list
  RecorderPanel.swift        the menu-bar .window panel: controls, meters, meetings, settings
  Shared.swift               small shared types/helpers
docs/research-notes.md       SDK-verified API rationale behind the design
```

---

## Out of scope (possible future work)

- Re-encoding the kept raw files to Opus/`.ogg` (the raw `.caf` files make this lossless).
- Continuous clock-drift slope correction for multi-hour recordings (sub-100 ms residual drift
  is acceptable for personal use).
- Acoustic echo cancellation (assumes headphones; AEC would muddy the deliberate hard channel
  separation).

---

## License

[MIT](LICENSE).
