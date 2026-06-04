# Research notes (SDK-verified, macOS 26.3 / Xcode 26.4)

## Synthesis (architecture decisions)

I'll produce the architecture recommendation. This is a synthesis task — I have all the research briefs and verification verdicts I need, so I'll write the decisive document directly.

# Audio Recorder — Architecture Recommendation (macOS 26.3, Swift 6.3 / Xcode 26.4)

This resolves all conflicts in favor of the verified verdicts. The two most important verdict-driven decisions: **(a) use TWO independent captures + post-merge, NOT a single tap+mic aggregate** (the single-aggregate "one clock" path is unproven, contradicts the only working reference, and couples two failure-prone streams against your data-safety goal), and **(b) add a zero-buffer watchdog** for the confirmed macOS 26.x process-tap regression.

---

## 1. Capture architecture

**Firm call: two independent captures, written to two raw files, merged on stop. Do NOT build a single aggregate containing both the tap and the mic.**

Rationale (from verdicts): the single tap+mic aggregate is theoretically attractive but **unverified** — AudioCap (the canonical working impl) never puts a hardware mic in the aggregate, the one author who tried adding an input device reported it "only confused matters," and a single IOProc whose stream stalls would lose *both* sources at once. Drift between two free-running clocks is real but is a solvable post-merge resample; data loss is not recoverable. Two files is the reference-backed, crash-resilient path.

**Desktop / system audio — Core Audio process tap (Approach A):**
- `CATapDescription(stereoGlobalTapButExcludeProcesses: [])` → entire system output mix as 2ch. Set `desc.uuid = UUID()`, `desc.muteBehavior = .unmuted` (passthrough — user still hears audio), `desc.isPrivate = true`.
- `AudioHardwareCreateProcessTap(desc, &tapID)` (`macos(14.2)`, not deprecated — verified in your SDK).
- Wrap in a **tap-only** private aggregate device: output device UID as `kAudioAggregateDeviceMainSubDeviceKey` ("master", drift comp off), the tap in `kAudioAggregateDeviceTapListKey` with `kAudioSubTapDriftCompensationKey: true`. This is exactly the AudioCap pattern. The mic is NOT a sub-device here.
- Read real format via `kAudioTapPropertyFormat` ('tfmt') → build `AVAudioFormat` from the ASBD. Do not hardcode rate/layout.
- Drive with `AudioDeviceCreateIOProcIDWithBlock` + `AudioDeviceStart`. Write each callback's buffer to disk immediately.

**Microphone — AVAudioEngine, separately:**
- `AVAudioEngine.inputNode.installTap(onBus:0, bufferSize:4096, format:)` where `format = inputNode.inputFormat(forBus: 0)` — **never hardcode 44100** (assertion crash; Bluetooth mics drop to 16 kHz).
- Auth: `AVCaptureDevice.authorizationStatus(for: .audio)` → `requestAccess(for: .audio)` (async). This is the macOS path — not `AVAudioSession`.

**Permissions / Info.plist / entitlements (non-sandboxed personal app):**

| Requirement | Value | Notes |
|---|---|---|
| System-audio tap | `NSAudioCaptureUsageDescription` (Info.plist) | TCC service `kTCCServiceAudioCapture`. Not in Xcode's dropdown — type the raw key. No API to pre-flight (private SPI only). Shows the **purple** privacy dot (verdict correction — the brief's "orange" was wrong), maps to "System Audio Recording Only" in Settings. **No Screen Recording permission needed.** |
| Microphone | `NSMicrophoneUsageDescription` (Info.plist) | TCC `kTCCServiceMicrophone`. Crashes on first request if missing. |
| Entitlements | **none** | Non-sandboxed local app relies purely on TCC. |

If sandboxed later: add `com.apple.security.app-sandbox` + `com.apple.security.device.audio-input` (see §6).

---

## 2. Recording-to-disk & data safety

**File layout:**
```
~/Documents/Recordings/{YYYY-M-D}-{HHMM}[-{meeting}]/
    desktop.caf      ← raw, Float32 PCM, from the tap
    mic.caf          ← raw, Float32 PCM, from AVAudioEngine
    audio.ogg        ← produced ONLY on stop (Opus-in-Ogg)
```

**Raw format: CAF, Float32 PCM, per source.** CAF over WAV because long recordings can exceed WAV's 4 GB ceiling; ffmpeg reads CAF directly (verified). Each source is written **mono** (pan happens at merge), matching the tap and mic channel handling.

**Flush cadence:** write every IOProc / tap callback straight to its `AVAudioFile` via `file.write(from:)` — `AVAudioFile` flushes per write, so a crash loses at most one buffer (~tens of ms). This continuous per-callback write *is* your data-safety guarantee. The `.ogg` is not safe until a clean stop (acceptable because raw files survive — see §3).

**Capture each stream's first-buffer `mHostTime`** (tap IOProc `inInputTime->mHostTime`; mic buffer host time) to compute the start-offset Δ for alignment at merge.

**Pause semantics (do NOT tear down the device):**
- **Pause:** flip `model.state = .paused`. Taps keep firing; a `guard state == .recording` skips `write(from:)`. Device stays live, meters keep moving, no format renegotiation/crash risk. Produces a gap in the file (paused audio dropped — correct for a recorder).
- **Resume:** flip back to `.recording`; writes append to the same files.
- **Stop:** stop engine + tap, `removeTap`, set the `AVAudioFile`s to `nil` (finalizes), then run merge.

---

## 3. Merge / pan / encode to .ogg

**Firm call: shell out to `/opt/homebrew/bin/ffmpeg` (8.1.1) on stop. Do NOT link libopus.** For a personal app, linking buys nothing except page-level live-flush, which you don't need (raw CAFs already provide durability). The final `.ogg` is produced **on stop only** — this is acceptable *because you keep the raw files* and can re-run the merge after any failure.

**Routing is empirically verified (both verdicts): desktop → input 0 → FL (hard LEFT), mic → input 1 → FR (hard RIGHT)** — matches your spec (mic right, desktop left). Input *index* binds the channel, so `-i desktop` MUST come before `-i mic`.

**The command (length-tolerant — this variant is mandatory, not optional):**
```bash
# 1. Compute LONGEST = max duration of the two raw files:
#    ffprobe -v error -show_entries format=duration -of csv=p=0 <file>
# 2. Merge. -t "$LONGEST" is REQUIRED: apad pads both to infinite,
#    so without -t the encode runs forever.
/opt/homebrew/bin/ffmpeg -y \
  -i desktop.caf -i mic.caf \
  -filter_complex "[0:a]apad[d];[1:a]apad[m];[d][m]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[a]" \
  -map "[a]" -t "$LONGEST" \
  -c:a libopus -b:a 96k -application audio \
  audio.ogg
```
- If sources are stereo, downmix each to mono first: `[0:a]pan=mono|c0=0.5*FL+0.5*FR,apad[d]` (same idea for mic).
- Add `-itsoffset <Δ>` before the later-starting input if the captured host-time delta shows meaningful skew.
- Run via `Process`; **guard with `FileManager.fileExists(atPath: "/opt/homebrew/bin/ffmpeg")`** first; capture stderr; check exit status. Only delete raw files if you choose to — **recommend keeping them.**

**Corrections from verdict (do not repeat the brief's errors):**
- **`libvorbis` is NOT available** on your ffmpeg build (`--enable-libopus` only, no `--enable-libvorbis`). Opus is the only good `.ogg` codec here — which is the better choice anyway.
- `.ogg` plays natively on macOS with Opus inside (verified via `afinfo`). `.opus` is the strictly-canonical extension, but you asked for `.ogg` and it works; just know strict players may key off the extension.

**Fallback if .ogg is ever problematic:** mix to a stereo `AVAssetWriterInput` → AAC `.m4a`, fully native, no external binary. This is also your fallback if ffmpeg is missing at the expected path.

---

## 4. Calendar (EventKit)

- `import EventKit`; create **one long-lived `EKEventStore`** (releasing it invalidates vended events).
- **Auth:** `requestFullAccessToEvents()` (async; `requestAccess(to:)` is deprecated). Need **full** access — write-only can't read. Switch on the `EKAuthorizationStatus` **case**, never raw value (`.authorized` and `.fullAccess` both = 3).
- **Info.plist:** `NSCalendarsFullAccessUsageDescription` (macOS 14+ key; the request fails/crashes without it). No entitlement needed (non-sandboxed).
- **Fetch window:** `predicateForEvents(withStart: now-2h, end: now+8h, calendars: nil)` (matches overlapping events) → `events(matching:)` (synchronous, unordered). Filter `isAllDay` and empty titles, sort by `startDate`, dedup on `eventIdentifier`.
- **Current meeting for naming:** in-progress (`start <= now <= end`) → else most-recently-started → else next upcoming.
- **Folder-name mapping:** `{YYYY-M-D}-{HHMM}` + `-{sanitized title}`. Sanitize: strip `/ : \ ? % * | " < >` and control chars, collapse whitespace → dashes, cap ~40 chars, trim leading dot/dash (avoid hidden folders). Empty title → `meeting`.
- **End detection:** EventKit has no end callback — drive a `Timer` from `endDate`; observe `.EKEventStoreChanged` to refetch on live edits.

---

## 5. App shell

- **`MenuBarExtra` with `.menuBarExtraStyle(.window)`** (macOS 13+). The `.window` style is required — `.menu` strips button styles and blocks the runloop. Fix panel width (~340pt); height grows to content. Label icon is state-driven (`record.circle.fill` when recording).
- **Agent app:** `LSUIElement = YES` in Info.plist (no Dock icon, no app-switcher entry). Provide an in-panel **Quit** button. Put settings *inside the popover* — the `Settings` scene is flaky from an accessory app.
- **App model:** `@MainActor @Observable final class RecorderModel` (Observation framework, macOS 14+). Inject via `.environment(model)`. State enum `{ idle, recording, paused }`. Engines/files/watchdog held as `@ObservationIgnored` properties. Audio threads compute RMS then hop to `@MainActor` to publish meter levels.
- **Notifications:** `UNUserNotificationCenter`. **Critical: the app must be code-signed** (even ad-hoc / "Sign to Run Locally" with a stable bundle ID) or the auth prompt silently never appears. Set delegate before `requestAuthorization([.alert, .sound])`. Implement `willPresent` → `[.banner, .sound]` so banners show for the accessory app. Register a "Stop Recording" action category. No usage-description string needed.
- **Silence auto-stop (both channels, ~5 min):** compute RMS→dBFS inside the *existing* capture taps via `vDSP_rmsqv` (Accelerate) — no extra taps. Track "last time *either* channel exceeded threshold" (tunable −45…−55 dBFS). A low-frequency (~5s) `Timer` checks if `now - lastSoundAt >= 300s` → `stopAndSave()`. Map dBFS→meter: `max(0, (db + 80) / 80)`.
- **Meeting-end auto-stop + notification:** schedule a one-shot `UNTimeIntervalNotificationTrigger` at the meeting's `endDate` (`interruptionLevel = .timeSensitive`) titled "Meeting ended — still recording," with a "Stop Recording" action; cancel it if recording stops first. On wake, re-check `hasEnded` against `Date()` (wall-clock timers don't fire reliably during sleep). Both silence and schedule triggers funnel into one `stopAndSave()`.
- **Tap watchdog (required — see §8):** if tap RMS ≈ 0 for N seconds while output is active, tear down and rebuild **both** the tap and the aggregate (rebuilding only one is insufficient per the regression report).

---

## 6. Sandbox / signing decision

**Firm call: do NOT sandbox.** A sandboxed app cannot exec `/opt/homebrew/bin/ffmpeg` and cannot freely write `~/Documents/Recordings` — both core to this design. Non-sandboxed, you `Process`-launch ffmpeg and write freely.

**Still sign** (ad-hoc/Developer-ID, stable bundle ID) + optionally notarize with Hardened Runtime — required for notifications to work and to avoid Gatekeeper warnings. TCC grants stick to a stable signing identity (rebuilding with a different/ad-hoc signature may re-prompt).

**Entitlements — non-sandboxed (recommended):** none. Rely on TCC + Info.plist strings (`NSAudioCaptureUsageDescription`, `NSMicrophoneUsageDescription`, `NSCalendarsFullAccessUsageDescription`) + a valid signature.

**Entitlements — IF you later sandbox (e.g. Mac App Store):** `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, `com.apple.security.personal-information.calendars`, `com.apple.security.files.user-selected.read-write` (with save-panel/security-scoped bookmark) — AND replace the ffmpeg subprocess with linked libopus encoding (§3 Path 2).

---

## 7. Project skeleton

**Xcode app project** (not SwiftPM) — you need an app bundle, Info.plist, signing, and capabilities. SwiftPM only enters if you ever switch to linked libopus.

```
Recorder/
  RecorderApp.swift          App entry: MenuBarExtra scene, NSApplicationDelegateAdaptor
  AppDelegate.swift          UNUserNotificationCenter setup/delegate, activation policy
  Model/
    RecorderModel.swift      @MainActor @Observable: state, levels, meetings, owns engines/files
    RecordingSession.swift   Folder URL, raw file URLs, start host-times, paths
  Capture/
    SystemAudioTap.swift     CATapDescription + tap-only aggregate + IOProc → desktop.caf; watchdog
    MicCapture.swift         AVAudioEngine inputNode tap → mic.caf; auth
    RMSMeter.swift           vDSP_rmsqv → dBFS helper
    SilenceMonitor.swift     dual-channel 5-min silence → onAutoStop
  Merge/
    OggMerger.swift          ffprobe durations + Process(ffmpeg) join/pan/encode; m4a fallback
  Calendar/
    CalendarAccess.swift     EKEventStore, auth, meetingsAroundNow, currentMeeting
    Meeting.swift            struct + folder-name sanitizer/mapper
  Notifications/
    NotificationManager.swift  schedule/cancel meeting-end alerts, actions
  UI/
    RecorderPanel.swift      .window-style panel: record/pause/save/trash, meters, meeting list, Quit
  Info.plist                 LSUIElement, the 3 usage strings
  Recorder.entitlements      (empty for non-sandboxed; or sandbox set if you switch)
```

**C-interop module map — only if you choose linked libopus (NOT the recommendation).** Xcode app targets ignore pkg-config, so set manually: Header Search Paths `/opt/homebrew/include`, Library Search Paths `/opt/homebrew/lib`, Other Linker Flags `-lopus -logg` (prefer static `libopus.a`/`libogg.a`, both arm64-present). Module map: `module Copus [system] { header "shim.h"  link "opus"  export * }` with `shim.h` → `#include <opus/opus.h>` (note the `opus/` subdir).

---

## 8. Top risks & open questions (decide before building)

1. **macOS 26.x zero-buffer tap regression (highest risk).** Confirmed: `AudioHardwareCreateProcessTap` + aggregate silently delivers all-zero PCM after extended uptime / sample-rate or Bluetooth changes, while IOProc keeps firing normally. **Decision: accept the mandatory watchdog (detect RMS≈0 while output active → rebuild tap+aggregate), or restrict to short recordings?** Recommend: build the watchdog — it's non-optional for long meetings.

2. **Clock drift between the two independent streams.** Over 60 min a ~20 ppm mismatch ≈ 72 ms slip. **Decision: is start-offset alignment (Δ from `mHostTime`) + ffmpeg resample-to-common-rate "good enough," or do you need continuous drift-slope correction?** Recommend: offset + resample is fine for a personal recorder; only add slope correction if you observe audible desync.

3. **Echo when no headphones.** The `.unmuted` tap adds no feedback loop, but the mic still acoustically re-captures speaker output. **Decision: assume headphones (recommended, zero code), or wire in Voice-Processing I/O AEC (heavier, conflicts with the clean two-source design)?** Recommend: assume headphones.

4. **Signing for notifications.** Notifications silently no-op if unsigned. **Decision: ad-hoc/"Sign to Run Locally" with a stable bundle ID (sufficient), or full Developer-ID + notarization?** Recommend: stable ad-hoc signature is enough for personal use; notarize only if you move it between machines.

5. **Output extension `.ogg` vs `.opus`.** You asked for `.ogg`; it works with Opus inside and plays natively, but `.opus` is the canonical label and some strict tools key off extension. **Decision: keep `.ogg` (your spec) or switch to `.opus`?** Recommend: keep `.ogg` per your spec — it's functionally correct.

---

# Detailed briefs

## system-audio-capture

All confirmed against the macOS 26.4 SDK on the user's machine. I have authoritative, current data for both approaches. Here is the technical brief.

---

# Technical Brief: Capturing Desktop / System Audio on macOS 26 from Swift

**Scope verified against your actual toolchain.** All availability annotations below were read directly from the SDK on your machine: `MacOSX26.4.sdk` (Xcode 26.4). Where I cite a version, it comes from the real `API_AVAILABLE(...)` macros in the framework headers, not from memory.

Bottom line up front: **Use Core Audio process taps (Approach A) for this app.** It is the lighter-weight, audio-native path, it does *not* require Screen Recording permission, it gives you a true global system-output tap, and it hands you Core Audio buffers with sample-accurate `mSampleTime`/`mHostTime` — exactly what you want for the record-two-files-then-merge-and-pan strategy. Details and the case for the alternative follow.

---

## Approach A — Core Audio Process Taps

### What it is and minimum OS

A "process tap" lets you tap the audio *output* of a device and a set of processes (or all processes), then read it as an input by wrapping it in a private **aggregate device** and installing an IO proc. The core functions live in `CoreAudio.framework`:

- `AudioHardwareCreateProcessTap(CATapDescription*, AudioObjectID*)` — `API_AVAILABLE(macos(14.2))`, `API_UNAVAILABLE(ios, watchos, tvos)` (confirmed in `AudioHardwareTapping.h`)
- `AudioHardwareDestroyProcessTap(AudioObjectID)` — `macos(14.2)`
- `AudioHardwareCreateAggregateDevice` / `AudioHardwareDestroyAggregateDevice` (long-standing)
- `AudioDeviceCreateIOProcIDWithBlock`, `AudioDeviceStart`, `AudioDeviceStop` (long-standing)
- `CATapDescription` class — `API_AVAILABLE(macos(12.0), ios(15.0))` on the class, but the tap *functions* gate it to 14.2.

The functions are annotated **14.2** in the SDK. The widely repeated "14.4" figure refers to when Apple shipped the documented sample / made it broadly usable; some early initializers landed in 14.2. For your target (macOS 26.3) this is moot — everything is present. Note: **not deprecated** in the 26.4 SDK (I grepped `AudioHardwareTapping.h` — no `API_DEPRECATED` markers, despite a 2025 forum thread speculating about it).

### `CATapDescription` initializers (exact signatures from your SDK's `CATapDescription.h`)

```objc
- (instancetype)initStereoMixdownOfProcesses:(NSArray<NSNumber*>*)processObjectIDs;
- (instancetype)initStereoGlobalTapButExcludeProcesses:(NSArray<NSNumber*>*)excludeIDs;   // ← global stereo
- (instancetype)initMonoMixdownOfProcesses:(NSArray<NSNumber*>*)processObjectIDs;
- (instancetype)initMonoGlobalTapButExcludeProcesses:(NSArray<NSNumber*>*)excludeIDs;     // ← global mono
- (instancetype)initWithProcesses:(NSArray<NSNumber*>*)includeIDs andDeviceUID:(NSString*)uid withStream:(NSInteger)stream;
- (instancetype)initExcludingProcesses:(NSArray<NSNumber*>*)excludeIDs andDeviceUID:(NSString*)uid withStream:(NSInteger)stream;
```

**For "all desktop audio," use `init(stereoGlobalTapButExcludeProcesses: [])`** — empty array means exclude nothing, i.e. tap the entire default-output mix. This is the global tap. (The `Mixdown` variants tap a *specific* set of processes; AudioCap uses `stereoMixdownOfProcesses:` for per-app capture.)

**macOS 26-new properties** (read from header, both `API_AVAILABLE(macos(26.0))`):
- `bundleIDs` — select tapped processes by bundle ID rather than only by audio-object ID. This is a meaningful 2025 improvement: previously you had to translate a live PID to an `AudioObjectID`, and excluding/including a PID that wasn't currently producing audio could fail or crash. `bundleIDs` is more robust. Not needed for a global tap, but useful if you later want "exclude my own app."
- `processRestoreEnabled` — lets the tap survive/re-bind as processes come and go.

Other notable properties (all pre-26): `name`, `UUID`, `processes`, `isMono`, `isExclusive`, `isMixdown`, `privateTap` (getter `isPrivate`), `muteBehavior` (`CATapMuteBehavior`: `.unmuted`, `.muted`, `.mutedWhenTapped`), `deviceUID`, `stream`.

> Mute behavior matters for your app: a global tap with `.unmuted` is **passthrough** — the user still hears their desktop audio while you record it. That is what you want. `.mutedWhenTapped` would silence the speakers while recording.

### Permissions — this is the key advantage

System-audio taps are gated by **TCC service `kTCCServiceAudioCapture`** — the *Audio* recording consent, **not** Screen Recording.

- **Info.plist key:** `NSAudioCaptureUsageDescription` (string explaining why you record audio). This key is **not** in Xcode's Info.plist dropdown — type the raw key in manually.
- **No Screen Recording permission required.** No purple screen-recording indicator. The user sees the orange microphone/audio indicator instead.
- There is **no public API to pre-flight or pre-prompt** this permission. Two real-world patterns:
  1. **Simplest (recommended for a personal app):** just call `AudioHardwareCreateProcessTap`. The first time you start recording, the system shows the TCC prompt using your `NSAudioCaptureUsageDescription` string. If denied, the tap produces silence / errors and you tell the user to enable it in System Settings → Privacy & Security → Audio Recording (the `kTCCServiceAudioCapture` pane).
  2. **Pre-flight (AudioCap's approach):** uses **private TCC SPI** — `TCCAccessPreflight("kTCCServiceAudioCapture", nil)` and `TCCAccessRequest("kTCCServiceAudioCapture", nil, handler)` — dynamically dlsym'd, behind a build flag. This lets you show status/ask ahead of time. **Private SPI** — fine for a local unsigned personal build; would be a App Store rejection risk and could break across OS updates. For your personal app it's optional polish, not required.

### Entitlements / signing

- **Unsigned / locally-run (your likely case):** no entitlements needed. TCC still applies and works.
- **If you sandbox the app** (`com.apple.security.app-sandbox`): you need `com.apple.security.device.audio-input`. A pragmatic personal app can simply **not** enable the sandbox.
- **If you sign + notarize for distribution:** add `NSAudioCaptureUsageDescription`, Hardened Runtime is required for notarization, and if sandboxed add the audio-input entitlement. The TCC model is identical; only packaging changes.

### Audio format you receive

Read it from the tap before building the file:

```swift
var asbd = try tapID.readAudioTapStreamBasicDescription()  // kAudioTapPropertyFormat ('tfmt')
```

`kAudioTapPropertyFormat` is `'tfmt'` (confirmed in `AudioHardware.h`). For a global stereo tap on a typical built-in output you get **Linear PCM, 32-bit float (`Float32`), commonly non-interleaved, 2 channels, at the output device's sample rate (usually 44.1k or 48k)**. Do not hard-code it — read the ASBD and build your `AVAudioFormat`/`AVAudioFile` from it. The mixdown/global "stereo" forms guarantee 2ch; "mono" forms give 1ch.

### Minimal code sketch (global tap → IO proc → file)

```swift
import CoreAudio
import AVFoundation

// 1. Global stereo tap of ALL processes (empty exclude list), passthrough so user still hears it.
let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
desc.uuid = UUID()
desc.muteBehavior = .unmuted
desc.isPrivate = true                       // don't show this tap globally

var tapID = AudioObjectID(kAudioObjectUnknown)
guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { /* TCC denied or error */ }

// 2. Wrap the tap in a PRIVATE aggregate device whose main sub-device is the current default output.
let outUID = try AudioObjectID.readDefaultSystemOutputDevice().readDeviceUID()
let aggDict: [String: Any] = [
    kAudioAggregateDeviceNameKey: "DesktopTap",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
    kAudioAggregateDeviceTapListKey: [[
        kAudioSubTapDriftCompensationKey: true,
        kAudioSubTapUIDKey: desc.uuid.uuidString
    ]],
]
var aggID = AudioObjectID(kAudioObjectUnknown)
AudioHardwareCreateAggregateDevice(aggDict as CFDictionary, &aggID)

// 3. Build the output file from the tap's real format.
var asbd = try tapID.readAudioTapStreamBasicDescription()
let format = AVAudioFormat(streamDescription: &asbd)!
let file = try AVAudioFile(forWriting: desktopURL,
                           settings: [AVFormatIDKey: asbd.mFormatID,
                                      AVSampleRateKey: format.sampleRate,
                                      AVNumberOfChannelsKey: format.channelCount],
                           commonFormat: .pcmFormatFloat32,
                           interleaved: format.isInterleaved)

// 4. IO proc: write every callback to disk immediately (your "flush frequently" goal).
let q = DispatchQueue(label: "desktop.tap", qos: .userInitiated)
var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, q) {
    inNow, inInputData, inInputTime, _, _ in
    // inInputTime is an UnsafePointer<AudioTimeStamp>: .mSampleTime, .mHostTime  ← your sync anchor
    guard let buf = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inInputData, deallocator: nil)
    else { return }
    try? file.write(from: buf)   // AVAudioFile flushes to disk per write
}
AudioDeviceStart(aggID, procID)
```

The IO-block signature is `(inNow, inInputData, inInputTime, outOutputData, inOutputTime)` where the data params are `UnsafePointer<AudioBufferList>` and the time params are `UnsafePointer<AudioTimeStamp>`. (Confirmed in AudioCap's `ProcessTap.swift`.) Teardown: `AudioDeviceStop`, `AudioDeviceDestroyIOProcID`, `AudioHardwareDestroyAggregateDevice`, `AudioHardwareDestroyProcessTap`.

### Sample-accurate timestamps for later sync

The `inInputTime: UnsafePointer<AudioTimeStamp>` in each callback carries:
- **`mSampleTime`** — continuous sample-frame counter for *this* tap/device timeline. Subtract the first callback's value to get a frame offset.
- **`mHostTime`** — `mach_absolute_time()` units. This is the cross-stream anchor: convert with `mach_timebase_info` to nanoseconds and align the desktop file against the mic file (whose buffers carry their own host time). Because you record two separate files, capturing each buffer's `mHostTime` at start lets ffmpeg's `-itsoffset` (or a computed sample offset) align them precisely on merge.

### Gotchas (Core Audio taps)

- **Default-output device changes at runtime.** The aggregate device is pinned to the output UID you passed. If the user switches output (e.g., plugs in AirPods), your tap may keep following the old device or go silent. Register an `AudioObjectAddPropertyListener` for `kAudioHardwarePropertyDefaultSystemOutputDevice` and rebuild the tap+aggregate on change. For a personal app you may simply restart recording.
- **Sample-rate mismatch / drift.** Set `kAudioSubTapDriftCompensationKey: true` (as above). The tap runs at the output device's rate; if you later mix with a 48k mic, resample in ffmpeg on merge.
- **Level attenuation on multi-output interfaces.** A documented bug: on devices exposing many stereo pairs (e.g., 8-out interfaces), the tap shows ~−12 dB attenuation scaled by pair count. Built-in speakers / AirPods (true 2ch) show ~0 dB. Not an issue for typical laptop use; normalize in ffmpeg if you hit it.
- **Silent buffers from some apps.** A few apps using non-standard audio paths can yield zero-filled buffers under per-process *mixdown* taps. A **global** tap avoids most of this because it taps the device output mix.
- **PID→AudioObject conversion fragility** (per-process only): translating a PID that isn't currently playing can fail. The global tap and the new 26.0 `bundleIDs` property both sidestep this.

---

## Approach B — ScreenCaptureKit `SCStream` audio-only

### What it is and minimum OS (from your SDK's `SCStream.h`)

`SCStream` delivers screen + audio sample buffers. For audio-only you set a tiny content filter, disable video pacing, and consume only audio outputs.

- `SCStreamConfiguration.capturesAudio` (system audio) — `API_AVAILABLE(macos(13.0))`
- `SCStreamConfiguration.excludesCurrentProcessAudio` — `macos(13.0)` (prevents recording your own app — avoids feedback)
- `SCStreamConfiguration.captureMicrophone` — `API_AVAILABLE(macos(15.0))` (+ `microphoneCaptureDeviceID`)
- `SCStreamOutputType`: `.audio` is `macos(13.0)`; `.microphone` is `macos(15.0)` (both confirmed in `SCStream.h`)
- Default audio config: **48000 Hz, 2ch** via `sampleRate` / `channelCount`.

**No new audio APIs in macOS 26** for SCK — the 2025/Tahoe SCK additions are about *screenshots* (the macOS 26 advanced screenshot APIs in `SCScreenshotManager.h`), not audio. System+mic audio capture and straight-to-file recording (`SCRecordingOutput`) are the macOS 15 (WWDC 2024) features. So on macOS 26 you'd be using the macOS-15-era audio surface.

### Permissions — the key disadvantage

`SCStream` requires **Screen Recording permission** (`kTCCServiceScreenCapture`), even for audio-only capture. There is no audio-only consent path through SCK.

- **Info.plist:** historically no dedicated SCK usage string was required because consent is handled by the system Screen Recording pane; if you also enable `captureMicrophone` you should provide `NSMicrophoneUsageDescription`.
- The user must grant **Screen & System Audio Recording** in System Settings, the app appears in that list, and macOS shows recurring "X is recording your screen" reminders. For an audio-only utility this is heavier and more alarming to the user than the audio indicator.
- macOS 15+ added periodic monthly re-consent prompts for screen recording — annoying for a long-lived background recorder.

### Entitlements / signing

Same story as A: unsigned local app needs no entitlement; sandboxed app interacting with mic needs `com.apple.security.device.audio-input`; notarization needs Hardened Runtime. Screen Recording consent is TCC, not an entitlement.

### Audio format you receive

`SCStreamOutputTypeAudio` buffers are **`CMSampleBuffer`s wrapping an `AudioBufferList`**, format driven by your `sampleRate`/`channelCount` (default 48k/2ch, Float32 PCM, non-interleaved). `SCStreamOutputTypeMicrophone` buffers use the **mic device's native format** (so you may need a resample/convert step to match). You convert to `AVAudioPCMBuffer` inside the delegate:

```swift
func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
    guard type == .audio, sb.isValid else { return }
    try? sb.withAudioBufferList { abl, _ in
        guard let asbd = sb.formatDescription?.audioStreamBasicDescription,
              let fmt = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                      channels: asbd.mChannelsPerFrame),
              let pcm = AVAudioPCMBuffer(pcmFormat: fmt, bufferListNoCopy: abl.unsafePointer)
        else { return }
        try? file.write(from: pcm)   // MUST stay inside this closure
    }
}
```

**Critical gotcha:** the buffer-list pointer from `withAudioBufferList` is valid **only inside the closure** — copy/write there; never stash the pointer.

### Minimal setup sketch

```swift
let content = try await SCShareableContent.current
let filter = SCContentFilter(display: content.displays.first!, excludingWindows: [])
let cfg = SCStreamConfiguration()
cfg.capturesAudio = true
cfg.excludesCurrentProcessAudio = true
cfg.sampleRate = 48000
cfg.channelCount = 2
if #available(macOS 15, *) { cfg.captureMicrophone = true }   // both sources via SCK if desired
cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)      // throttle the (unwanted) video
let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: q)
try await stream.startCapture()
```

### Sample-accurate timestamps

Each `CMSampleBuffer` carries `CMSampleBufferGetPresentationTimeStamp(sb)` (a `CMTime`, on the host/mach clock). SCK timestamps system audio and mic on a shared timeline, which is a genuine convenience **if you capture both sources through SCK** — they're already co-timestamped. The PTS is host-clock-based, comparable to Core Audio's `mHostTime`.

### Gotchas (ScreenCaptureKit)

- **Screen Recording consent** (above) — the biggest practical drawback for an audio-only app.
- **Long-running crash** reported: `EXC_BAD_ACCESS` in `swift_getErrorValue` from `didStopWithError` during extended captures — relevant for an app meant to record long meetings.
- **Mic + audio file corruption** reports when combining `captureMicrophone` with file output in some configurations.
- **You're paying for a video pipeline you don't want** — even throttled, SCK spins up screen capture machinery; higher overhead than a pure audio tap.
- Mic buffers arrive in the **device's native format**, not your configured 48k/2ch — you must convert before mixing.

---

## Recommendation for your app: **Approach A (Core Audio process taps)**

Reasons, weighted to your specific goals (one-click, two-source, pan L/R, .ogg, frequent flush, personal app):

1. **Correct permission model.** A taps app needs only **Audio Recording** consent (`kTCCServiceAudioCapture` + `NSAudioCaptureUsageDescription`). SCK forces **Screen Recording** consent plus recurring "recording your screen" nags — wrong and alarming for an audio utility.
2. **True global desktop mix.** `init(stereoGlobalTapButExcludeProcesses: [])` gives you the entire system output as a clean 2ch stream — exactly the "desktop audio" channel you need, with `.unmuted` passthrough so the user still hears it.
3. **Native, low-overhead audio.** No video pipeline, lower CPU, fewer moving parts than SCK. No reports of the long-capture `swift_getErrorValue` crash that plagues SCK.
4. **Ideal for your "two files then merge" strategy.** Run **one tap for desktop** (this approach) and capture the **mic via `AVAudioEngine`/`AVCaptureSession`** separately — two independent `AVAudioFile`s, each written per-callback (frequent flush, crash-resilient). Each buffer's **`mHostTime`** is your alignment anchor; on stop, merge with ffmpeg, pan, and encode to Opus/.ogg:
   ```
   ffmpeg -i desktop.caf -i mic.caf -filter_complex \
     "[0:a]pan=mono|c0=0.5*c0+0.5*c1[d];[1:a]pan=mono|c0=0.5*c0+0.5*c1[m];\
      [d][m]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[a]" \
     -map "[a]" -c:a libopus -b:a 96k output.ogg
   ```
   (Desktop → LEFT/FL, mic → RIGHT/FR, per your spec. `-itsoffset` if you need to nudge alignment from the captured host-time delta.) Keep the raw `.caf` files as you planned.
5. **macOS 26 bonus.** If you later want "record everything except my own app's sound," the new `bundleIDs` property (`macos(26.0)`) makes exclusion robust without fragile PID translation.

**When B would win instead:** if you wanted *both* mic and system audio co-timestamped through a *single* framework with the least code (SCK gives you both on one timeline), or if you needed per-window app-audio capture tied to on-screen content. Neither outweighs the permission and overhead costs for your use case — and you can capture the mic perfectly well with AVFoundation alongside the tap.

> One practical note on raw files: write the per-source files as **`.caf` (or `.wav`) Float32**, not `.ogg`, during capture — encode to Opus/.ogg only at the merge step. Opus/ogg isn't a good incremental/crash-safe streaming target for `AVAudioFile`, and your stated strategy (keep raw, encode on stop) already matches this.

---

## Key source files on this machine (authoritative, already on disk)

- `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.4.sdk/System/Library/Frameworks/CoreAudio.framework/Headers/CATapDescription.h` — initializers + `bundleIDs`/`processRestoreEnabled` (`macos(26.0)`).
- `.../CoreAudio.framework/Headers/AudioHardwareTapping.h` — `AudioHardwareCreateProcessTap`/`Destroy` (`macos(14.2)`, not deprecated).
- `.../CoreAudio.framework/Headers/AudioHardware.h` (~line 2011) — `kAudioTapPropertyUID 'tuid'`, `kAudioTapPropertyDescription 'tdsc'`, `kAudioTapPropertyFormat 'tfmt'`.
- `.../ScreenCaptureKit.framework/Headers/SCStream.h` — `capturesAudio`/`excludesCurrentProcessAudio` (`macos(13.0)`), `captureMicrophone` (`macos(15.0)`), `SCStreamOutputType.audio` (13.0) / `.microphone` (15.0).

## URLs

- Apple — Capturing system audio with Core Audio taps: https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
- Apple — `AudioHardwareCreateProcessTap(_:_:)`: https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)
- Apple — `CATapDescription`: https://developer.apple.com/documentation/coreaudio/catapdescription
- Apple — `SCStreamConfiguration.capturesAudio`: https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio
- Apple — ScreenCaptureKit framework: https://developer.apple.com/documentation/screencapturekit/
- Apple — Capturing screen content in macOS (sample, audio buffer handling): https://developer.apple.com/documentation/ScreenCaptureKit/capturing-screen-content-in-macos
- WWDC24 — ScreenCaptureKit (mic capture, straight-to-file): https://developer.apple.com/videos/play/wwdc2024/10088/
- insidegui/AudioCap (reference impl: tap → aggregate → IO proc → AVAudioFile; TCC SPI pattern): https://github.com/insidegui/AudioCap
- makeusabrew/audiotee (global tap, default-output-only, sample-rate notes): https://github.com/makeusabrew/audiotee
- Strongly Typed — AudioTee write-up (global/exclusive tap semantics): https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos
- sudara gist — early Core Audio Tap example: https://gist.github.com/sudara/34f00efad69a7e8ceafa078ea0f76f6f
- whisper.cpp discussion — SCK `withAudioBufferList` pitfalls: https://github.com/ggml-org/whisper.cpp/discussions/2704
- Rogue Amoeba — macOS 26 Tahoe audio bug fixes (recommend 26.1+): https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/
- Apple Developer Forums — `AudioHardwareCreateProcessTap` discussion: https://developer.apple.com/forums/thread/825780

---

## ogg-opus-encoding

I have fully verified everything empirically and confirmed the documentation. I have all the facts needed to deliver a comprehensive, concrete answer. This is a research/recommendation task (not a code-writing task), so I'll return the findings directly rather than writing a plan file.

---

# Producing the final .ogg file on macOS 26 — verified findings & recommendation

All commands below were **executed and verified** against your actual environment: `ffmpeg 8.1.1` at `/opt/homebrew/bin/ffmpeg` (built `--enable-libopus`, with `oga`/`ogg`/`opus` muxers and the `join`/`amerge`/`pan`/`apad`/`amix` filters all present), and Homebrew `opus 1.6.1` / `libogg 1.3.6` / `libvorbis 1.3.7` with working `.pc`/`.a`/`.dylib` files and headers under `/opt/homebrew/include`.

## TL;DR recommendation

For a personal, reliability-first app: **Path 1 (shell out to ffmpeg) is the right primary choice**, combined with your "record raw per-source files, merge on stop" strategy. Path 2 (link libopus/libogg) is real and viable but buys you nothing here except packaging pain. Path 3 (AVAssetWriter → AAC/`.m4a`) is the best *fallback* and arguably a better real-time-flush target than ogg.

The cleanest architecture: **record each source live with `AVAssetWriter` to its own `.caf` (or `.wav`), then on stop shell out to ffmpeg to pan+merge+encode to one Opus-in-Ogg file, keeping the raw CAFs.** This gives you frequent-flush durability from Apple's native writer *and* the ogg output you want, while the raw files survive even if the merge step ever fails.

---

## Path 1 — Shell out to ffmpeg (RECOMMENDED)

### The exact command (verified working)

Two **mono** inputs, desktop hard-LEFT, mic hard-RIGHT, Opus-in-Ogg out:

```bash
/opt/homebrew/bin/ffmpeg -y \
  -i desktop.caf \
  -i mic.caf \
  -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[a]" \
  -map "[a]" -c:a libopus -b:a 96k -application audio \
  audio.ogg
```

- Input **0 = desktop → FL (left)**, input **1 = mic → FR (right)**. I confirmed the routing empirically: encoding the mic at `volume=0.1` (−20 dB) produced FL RMS −21 dB vs FR RMS −41 dB — exactly the 20 dB delta, proving `0.0-FL` is desktop and `1.0-FR` is mic. **Order of `-i` matters; the input index in the map, not the filename, is what binds the channel.**
- `.ogg` extension auto-selects the Ogg muxer; **`.opus` selects the dedicated "Ogg Opus" muxer** — both verified to produce `codec_name=opus, channels=2, channel_layout=stereo`. Use `.opus` if you want players to label it Opus explicitly; `.ogg` is fine and is what you asked for.

### Variants you'll actually need

**If sources are stereo** (downmix each to mono first, then pan):
```bash
/opt/homebrew/bin/ffmpeg -y -i desktop.caf -i mic.caf \
  -filter_complex "[0:a]pan=mono|c0=0.5*FL+0.5*FR[d];[1:a]pan=mono|c0=0.5*FL+0.5*FR[m];[d][m]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[a]" \
  -map "[a]" -c:a libopus -b:a 96k audio.ogg
```
(Verified: exit 0, output `2,stereo`.)

**Mismatched lengths — this is the gotcha.** Real recordings won't be identical length. I confirmed: **`join` truncates to the shortest input** (desktop 5 s + mic 3 s → 3.006 s output). To preserve the *full* length of both, pad with silence:
```bash
/opt/homebrew/bin/ffmpeg -y -i desktop.caf -i mic.caf \
  -filter_complex "[0:a]apad[d];[1:a]apad[m];[d][m]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[a]" \
  -map "[a]" -shortest -t <longest_seconds> -c:a libopus -b:a 96k audio.ogg
```
(`apad` pads both to "infinite"; `-t <longest>` caps to the longer of the two. Verified: produced 5.006 s as intended. Compute `<longest_seconds>` from the two raw files via `ffprobe -show_entries format=duration`.)

**Equivalent alternative** to `join` is `amerge,pan` (verified identical routing): `-filter_complex "[0:a][1:a]amerge=inputs=2,pan=stereo|c0=c0|c1=c1[a]"`. Prefer `join` — it gives explicit channel-layout control and is easier to read.

### Encoder tuning (from the live `-h encoder=libopus` dump)
- `-c:a libopus` is the high-quality encoder (FFmpeg also has a native `opus` encoder, but **libopus is better — use it**).
- `-application audio` (default) for music/mixed; `voip` if it's purely speech.
- `-b:a 96k` is a good stereo voice+desktop default; bump to 128k for music. VBR is on by default.
- `-frame_duration` defaults to 20 ms; leave it.

### Reliability
Very high. ffmpeg 8.1.1 is current, the pipeline is a single deterministic batch invocation on stop, and you keep the raw files. Run it via `Process`/`NSTask`, capture stderr, check exit status, and only delete raw files if you choose to (recommend **keeping** them, per your strategy). One subtlety: it's a one-shot post-process, so it does *not* itself give "frequent flush during recording" — that durability comes from the live writer in front of it (see Path 3 / architecture).

### Licensing / distribution
- **Opus itself**: 3-clause BSD, royalty-free, with perpetual irrevocable patent grants from Xiph/Broadcom/Microsoft. No royalties to integrate or distribute. (Caveat: defensive-termination clauses if *you* sue over Opus patents — irrelevant for a personal app.) Source: opus-codec.org/license.
- **Depending on the Homebrew ffmpeg** (`/opt/homebrew/bin/ffmpeg`): perfect for a personal/local app — zero distribution concern. But note **your build is configured `--enable-gpl --enable-version3`** (it pulls in x264/x265). That makes the *binary* GPLv3-ish. For a personal unsigned app this is a non-issue. **It becomes a real issue only if you bundle and redistribute that ffmpeg binary** — then you inherit GPL obligations (offer source, etc.).
- **If you ever distribute**: either (a) keep shelling out to a *user-installed* ffmpeg (no bundling, no GPL transfer), or (b) bundle a **minimal LGPL ffmpeg** built `--disable-gpl` with only `--enable-libopus` (Opus is BSD, libavcodec/format are LGPL → dynamic linking keeps you LGPL-clean), or (c) drop ffmpeg and use Path 2. For signed/notarized distribution, a bundled ffmpeg in `Contents/Helpers/` must itself be signed with the hardened runtime and your launching app needs no special entitlement to exec it (it's your own bundled binary).

---

## Path 2 — Link libopus + libogg directly via Swift C interop

Fully viable on your machine — I confirmed `libopus.a` (arm64, contains `_opus_encode`/`_opus_encoder_create`), `libogg.a`, headers present, and working `.pc` files (`pkg-config --libs opus` → `-lopus`, etc.).

### SwiftPM setup (system library targets)

`Package.swift`:
```swift
// swift-tools-version: 6.0
import PackageDescription
let package = Package(
  name: "OggOpus",
  targets: [
    .systemLibrary(name: "Copus",  path: "Sources/Copus",  pkgConfig: "opus"),
    .systemLibrary(name: "Cogg",   path: "Sources/Cogg",   pkgConfig: "ogg"),
    .target(name: "OggOpus", dependencies: ["Copus", "Cogg"]),
  ]
)
```

`Sources/Copus/module.modulemap`:
```
module Copus [system] {
  header "shim.h"
  link "opus"
  export *
}
```
`Sources/Copus/shim.h`: `#include <opus/opus.h>` (note the `opus/` subdir — that's how the headers install). Same pattern for `Cogg` with `#include <ogg/ogg.h>` and `link "ogg"`.

Build with the Homebrew prefix on the pkg-config path:
```bash
PKG_CONFIG_PATH=/opt/homebrew/lib/pkgconfig swift build
```
(In Xcode you instead add `/opt/homebrew/include` to **Header Search Paths**, `/opt/homebrew/lib` to **Library Search Paths**, and `-lopus -logg` to **Other Linker Flags** — pkg-config isn't consulted by Xcode app targets.)

### The encode loop (high level — verified the symbols exist)
1. `opus_encoder_create(48000, 2, OPUS_APPLICATION_AUDIO, &err)` → `OpusEncoder*`.
2. `ogg_stream_init(&os, serialno)`.
3. Write the two Ogg Opus header packets first (the **OpusHead** ID header — magic `"OpusHead"`, version 1, channel count, pre-skip, input samplerate, **output gain**, mapping family 0 — and the **OpusTags** comment header), `ogg_stream_packetin` then `ogg_stream_flush` each so each header starts its own page (required by the Ogg Opus spec, RFC 7845).
4. Per 20 ms frame (960 samples/ch at 48 kHz): interleave your already-panned stereo (desktop→L, mic→R) and call `opus_encode(enc, pcm, 960, packet, maxLen)`. Wrap the returned bytes in an `ogg_packet` (set `granulepos` = running 48 kHz sample count, `e_o_s` on the last), `ogg_stream_packetin`, then drain with `ogg_stream_pageout` and append each page's `header`+`body` to your file.
5. To **flush frequently** (your durability requirement): call `ogg_stream_flush` periodically (e.g. every N frames or every second) to force completed pages to disk, then `FileHandle.write` + `fsync`. This is the one place Path 2 genuinely beats shelling out — you control flush cadence at the page level.

### Distribution
- **Static-link** `libopus.a` + `libogg.a` (both arm64, present) → self-contained, no runtime dylib search, simplest signing story. Recommended if you go this route.
- **Dynamic** (`.dylib`) requires bundling into `Contents/Frameworks/`, fixing install names with `install_name_tool`/`@rpath`, and re-signing each dylib — more work.
- **Hardened runtime**: statically-linked code is fine. The Homebrew dylibs are ad-hoc signed (`codesign -dv` shows `Identifier=libopus.0`, no team) so if you bundle them you must re-sign with your identity for notarization.

**Verdict on Path 2**: correct and not that hard, but for a *personal* app it adds C-interop surface, manual Ogg framing, and signing chores for essentially the same output ffmpeg gives you in one line. Choose it only if you want zero external-binary dependency or need page-level flush during live encoding.

---

## Path 3 — Apple-native fallback (AVAssetWriter → AAC `.m4a` or CAF)

Not ogg, but the **best real-time durable writer** and your natural live-recording layer.

- **`AVAssetWriter`** (AVFoundation, macOS 10.7+) writes incrementally: `startWriting()` → `startSession(atSourceTime:)` → append `CMSampleBuffer`s via `AVAssetWriterInput` (`expectsMediaDataInRealTime = true`) → `finishWriting`. Supports `.m4a`/AAC, `.caf`, `.wav`, `.aiff`, ALAC. This is what feeds your "frequent flush to avoid data loss" requirement *during* recording.
- **`.caf`** is the ideal raw container for the per-source files: no 4 GB size limit (unlike WAV), Apple-native, and ffmpeg reads it directly (verified `caf` muxer/demuxer present). Use **`.caf` over `.wav`** precisely because long recordings can exceed WAV's 4 GB ceiling.
- As a **pure fallback if ogg ever becomes a problem**: just point a single mixed-stereo `AVAssetWriterInput` at a `.m4a`/AAC file — fully native, no ffmpeg, no libs. It's AAC not Opus, but perfectly acceptable for personal use.

---

## Recommended architecture (ties the strategy together)

1. **Live capture** → two `AVAssetWriter`s, each writing its own source to `~/Documents/Recordings/{date}/desktop.caf` and `mic.caf`, appending buffers as they arrive (this is your frequent-flush durability — raw audio is on disk continuously).
2. **On stop** → mark inputs finished, `finishWriting`, then shell out to `/opt/homebrew/bin/ffmpeg` with the verified `join ... map=0.0-FL|1.0-FR` command (use the `apad`+`-t longest` variant to tolerate length differences) → `audio.ogg`.
3. **Keep the raw `.caf` files.** If the ffmpeg step ever fails (missing binary, bad args), the recording is still fully recoverable; just re-run the merge.
4. Fallback switch: if you decide ogg isn't worth it, swap step 2 for a native AAC `.m4a` merge via a third `AVAssetWriter` and drop the ffmpeg dependency entirely.

This interacts cleanly with "record raw per-source, merge on stop": Path 1 *is* a merge-on-stop tool (ideal fit); Path 2 could also be the merge step but you'd hand it raw PCM; Path 3 is both the live recorder and the fallback merger.

---

## Sources
- FFmpeg filters (join/amerge/pan/apad): https://ffmpeg.org/ffmpeg-filters.html
- join filter `map=0.0-FL|1.0-FR` syntax explained: https://hhsprings.bitbucket.io/docs/programming/examples/ffmpeg/manipulating_audio/channelsplit_join_amix_amerge.html
- Opus license (BSD, royalty-free, patent grants): https://opus-codec.org/license/
- Ogg Opus container spec (OpusHead/OpusTags framing): https://datatracker.ietf.org/doc/html/rfc7845
- libopus API (`opus_encoder_create`, `opus_encode`): https://opus-codec.org/docs/opus_api-1.5/
- AVAssetWriter (incremental writing, file types, macOS 10.7+): https://developer.apple.com/documentation/avfoundation/avassetwriter
- AVAssetWriterInput: https://developer.apple.com/documentation/avfoundation/avassetwriterinput
- SwiftPM system library targets / module maps: https://developer.apple.com/documentation/packagedescription/target/systemlibrary(name:path:pkgconfig:providers:)

**Key file paths confirmed on this machine:** ffmpeg `/opt/homebrew/bin/ffmpeg` (v8.1.1, `--enable-libopus`, GPL/version3); static libs `/opt/homebrew/lib/libopus.a`, `/opt/homebrew/lib/libogg.a` (both arm64); headers `/opt/homebrew/include/opus/opus.h`, `/opt/homebrew/include/ogg/ogg.h`; pkg-config dir `/opt/homebrew/lib/pkgconfig` (`opus.pc`, `ogg.pc`, `vorbis.pc`).

---

## mic-capture-and-sync

# Technical Brief — Microphone capture + avoiding sync drift / echo between mic and system-audio streams

**Scope:** macOS 26.3 (Darwin 25), Swift 6.3 / Xcode 26.4, Apple Silicon, personal menu-bar SwiftUI app. Target output: mic panned hard RIGHT, desktop/system audio panned hard LEFT, mixed to a single stereo `.ogg`.

## Bottom line (recommendation first)

**Do NOT run two independent `AVAudioEngine`s (one for mic, one for the process tap) and merge files afterward.** That is the "merge-on-stop" path, and it is the one that drifts and risks echo. The two streams come from **different clock domains** — the mic's hardware ADC clock vs. the Core Audio process-tap clock driven by the output device — and they free-run at slightly different real rates (e.g. 44099.6 Hz vs. 48000.3 Hz). Over a 60-minute meeting even a 20 ppm mismatch is ~72 ms of slip; mic and desktop audio will visibly de-sync.

**The robust, lowest-drift path on macOS 14.2+ (and fully current on 26.3): build ONE private Core Audio aggregate device that contains BOTH the system-audio process tap AND the microphone as a sub-device, with drift compensation enabled on the non-clock members.** Drive it with a single IOProc (or a single `AVAudioEngine` pointed at the aggregate). Both sources are then pulled in lockstep on ONE clock — Core Audio's HAL resamples the drifting member in real time, so there is zero accumulated drift and no post-hoc alignment math. This is exactly what aggregate devices were designed for.

The "record-each-source-to-its-own-file-then-merge" strategy from the hint is the *fallback*, not the primary. Keep it only as a safety net (see §6).

---

## 1. Microphone capture + authorization (macOS 26)

**Info.plist (required):**
- `NSMicrophoneUsageDescription` (string) — mic prompt text. App **crashes** on first request without it.
- `NSAudioCaptureUsageDescription` (string) — **separate** key for the system-audio tap. Not in Xcode's dropdown; type it manually. There is **no API to query** tap authorization status — denial just yields silence, so probe early.

**Entitlements (only if sandboxed / notarized for distribution):**
- `com.apple.security.device.audio-input` (Audio Input capability). For a personal, locally-run, possibly-unsigned app you can skip the sandbox entirely and just rely on the TCC prompts. If you later sign+notarize, add this entitlement; tap capture additionally needs the audio-input entitlement when the tapped device exposes input streams.

**Authorization API (current, async/await):**
```swift
import AVFoundation

func ensureMic() async -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized: return true
    case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
    default: return false   // .denied / .restricted
    }
}
```
`AVCaptureDevice.authorizationStatus(for: .audio)` → `.notDetermined/.authorized/.denied/.restricted`; `AVCaptureDevice.requestAccess(for: .audio)` triggers the prompt. (`AVAudioSession`/`requestRecordPermission` is the iOS path — on macOS use `AVCaptureDevice`.)

**Capture options for the mic alone:** `AVAudioEngine.inputNode` + `installTap(onBus:bufferSize:format:block:)`, or `AVAudioRecorder` for a simple file. **Critical pitfall:** never hardcode 44100 in the tap format — derive it from the live node (`inputNode.inputFormat(forBus: 0)`), or you hit the assertion `format.sampleRate == inputHWFormat.sampleRate`. The input format changes with the device (Bluetooth mics drop to 16 kHz; AirPods expose a 1-ch 16 kHz input vs. 2-ch 48 kHz output — the classic drift trigger). But for the recommended design you won't tap the mic directly — it goes into the aggregate (§3).

---

## 2. Why naive two-engine capture drifts (the core problem)

- **Two clock domains.** The mic device is clocked by its own ADC crystal. The process tap is clocked by whatever output device is playing system audio. Audio hardware never runs at its nominal rate exactly (44100 claimed ≠ 44100 actual). Two free-running crystals diverge linearly with time.
- **Possibly different sample rates.** Mic 44.1/48 kHz, tap format from `kAudioTapPropertyFormat` is whatever the output device runs (commonly 48 kHz). Mixing requires resampling to a common rate regardless.
- **Start-time skew.** Two engines never start on the same sample. Their first buffers correspond to different wall-clock instants.

**What it would take to align two separate files (the hard way):** capture a shared timebase for each stream's first sample — `mach_absolute_time()` / the `AudioTimeStamp.mHostTime` delivered in the render callback (host time is in the `mach_absolute_time` domain; convert with `mach_timebase_info`). Compute Δ = host time of mic's first sample − host time of tap's first sample, **pad the later-starting stream with Δ of leading silence**, **resample both to a common rate**, then **continuously resample one stream to correct the residual linear drift** (you must estimate the drift slope from the host-time progression, because padding only fixes the start offset, not the slope). This is sample-accurate *in principle* but fragile: you're reimplementing what the HAL already does, and any error in the drift slope estimate reintroduces slip. **Not recommended as the primary approach.**

---

## 3. Recommended architecture — single aggregate device (tap + mic, one clock)

macOS 14.2+ Core Audio process taps (`CATapDescription`, `AudioHardwareCreateProcessTap`) plus an aggregate device. AVAudioEngine is limited to a single device for I/O, which is *why* the aggregate is the right primitive: it presents the tap **and** the mic as one logical input device on one clock.

**Sequence:**
1. `CATapDescription` for system audio. Use `init(stereoMixdownOfProcesses:)` to capture specific apps, or `init(monoGlobalTapButExcludeProcesses:)` with an empty array for *all* system output (inverted/exclusive global tap). Set `tap.uuid = UUID()` and `tap.muteBehavior = .unmuted` (so you still hear the meeting — `.mutedWhenTapped` would silence playback). **`.unmuted` is the echo-relevant setting** (see §5).
2. `AudioHardwareCreateProcessTap(tapDescription, &tapID)`.
3. Build the aggregate dictionary — **add the mic as a sub-device alongside the tap.** Based on the canonical AudioCap implementation, extended to include the microphone:
```swift
let desc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "RecorderAgg",
    kAudioAggregateDeviceUIDKey: aggregateUID,                 // fresh UUID string
    kAudioAggregateDeviceMainSubDeviceKey: micUID,             // mic = master clock
    kAudioAggregateDeviceIsPrivateKey: true,                   // hidden from system
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [ kAudioSubDeviceUIDKey: micUID,
          kAudioSubDeviceDriftCompensationKey: false ]         // master: no comp
    ],
    kAudioAggregateDeviceTapListKey: [
        [ kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
          kAudioSubTapDriftCompensationKey: true ]             // tap follows mic clock
    ]
]
```
   **Drift-compensation rule:** the master/clock sub-device (`kAudioAggregateDeviceMainSubDeviceKey`) gets compensation **off**; every other member gets it **on**. Here the mic is master (best for clean mic, since the mic is the perceptually critical stream) and the tap is resampled to track it via `kAudioSubTapDriftCompensationKey: true`. You may instead pick the output device as master — either works; just keep exactly one master with comp off. Set the keys **explicitly** — Audio MIDI Setup auto-checks some members and misses others; do not rely on defaults.
4. `AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)`. Handle the "already exists" error `'kexi'` (1852797029) by destroying/reusing.
5. Read format: `kAudioTapPropertyFormat` → `AudioStreamBasicDescription` → matching `AVAudioFormat`. The tap delivers a 2-channel stream (typically L/R mixdown).
6. `AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, queue, ioBlock)` then `AudioDeviceStart(aggID, procID)`. In the block you receive **one `AudioBufferList` carrying both members' channels on the same clock** — mic channel(s) + tap L/R. Split them, pan, and write.
7. Teardown: `AudioDeviceStop` → `AudioDeviceDestroyIOProcID` → `AudioHardwareDestroyAggregateDevice` → `AudioHardwareDestroyProcessTap`.

**Documented sample-code bug to avoid:** Apple's doc snippet for *mutating* `kAudioAggregateDevicePropertyTapList` after creation passes the **tapID** as the target `AudioObjectID`; it must be the **aggregate device ID** for both get and set. Build the full tap list at creation time (as above) to sidestep it.

### Pros / cons vs. two separate engines
| | Single aggregate (tap+mic) | Two separate engines, merge files |
|---|---|---|
| Clock | **One.** HAL resamples drifters in real time → **zero accumulated drift** | Two free-running clocks → linear drift |
| Start alignment | Automatic (same IOProc tick) | Manual host-time Δ padding required |
| Sample-rate unify | HAL handles it | You resample both |
| Sync accuracy over 1 h | Sample-locked | Needs continuous drift-slope correction or it slips |
| Complexity | Core Audio C API (verbose, but a solved pattern) | "Simpler" per-stream, but alignment logic is the hard part |
| Robustness to device change | Aggregate must be rebuilt if mic/output changes | Each engine adapts independently |

The aggregate wins decisively on the one thing that matters here (no drift). Its only real downside is the verbose Core Audio setup — which AudioCap already provides as a working template.

---

## 4. The merge-on-stop approach — is sample-accuracy achievable?

Achievable only *approximately*, and only with real effort: you must (a) timestamp each stream's first sample with a shared host-time base, (b) pad the start offset, (c) resample to a common rate, AND (d) continuously correct the residual drift slope. (a)–(c) fix the *offset*; without (d) you still drift. Because you'd be hand-rolling the HAL's job with worse information, **the single aggregate device is the better way to get both on ONE clock.** Keep merge-on-stop only as the crash-safety fallback in §6.

---

## 5. Echo

Echo (the meeting hearing themselves) is a *different* problem from drift, caused by the mic re-capturing speaker output. Mitigations, in order:
1. **Headphones** eliminate it physically — the simplest real fix for a personal app.
2. **Capture, don't double-play.** With `muteBehavior = .unmuted` the tap copies audio without adding a second playback path, so the tap itself introduces no echo. (`.mutedWhenTapped` would mute the meeting for you — wrong for listening.)
3. **No software loopback into the mic** — the aggregate routes the tap as an *input*, never re-output, so you don't create a feedback loop.
4. True acoustic echo cancellation (mic picking up speaker sound without headphones) would require AEC via `kAudioUnitSubType_VoiceProcessingIO` (Voice-Processing I/O AU). That AU also does its own mic capture; it's heavier and conflicts with the clean two-source design. For a personal recorder, **recommend headphones** rather than wiring in VPIO.

---

## 6. Crash-safety / frequent-flush (the user's data-loss concern)

Even with the single aggregate, write incrementally:
- In the IOProc, split the buffer and append to **two raw `AVAudioFile`s** (mic.caf, desktop.caf) as CAF/WAV PCM — cheap, append-friendly, and because both came off one clock they're already sample-aligned, so the "padding/offset" math is unnecessary.
- Flush frequently. On stop (or crash recovery), run the merge/pan/encode pass. Keep raw files per the user's hint.

**Merge + pan (mic→R, desktop→L) + Opus/Ogg encode via the installed ffmpeg 8.1.1 (libopus present):**
```bash
/opt/homebrew/bin/ffmpeg -i desktop.caf -i mic.caf -filter_complex \
"[0:a]pan=mono|c0=c0[L];[1:a]pan=mono|c0=c0[R];[L][R]amerge=inputs=2,pan=stereo|c0=c0|c1=c1[a]" \
-map "[a]" -c:a libopus -b:a 96k output.ogg
```
This forces desktop into the left channel and mic into the right (`amerge` then `pan=stereo|c0=c0|c1=c1`). Because both raw files share the aggregate's single clock, no `-itsoffset` start-padding is needed. (If you ever fall back to two-engine capture, you'd add `-itsoffset <Δ>` computed from host-time stamps.) `.ogg` with `libopus` is confirmed available; `libvorbis` is also present if you prefer Vorbis.

---

## Sources
- [Capturing system audio with Core Audio taps — Apple](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [CATapDescription — Apple](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [AVCaptureDevice.requestAccess(for:) — Apple](https://developer.apple.com/documentation/avfoundation/avcapturedevice/1624584-requestaccess)
- [AVCaptureDevice.authorizationStatus(for:) — Apple](https://developer.apple.com/documentation/avfoundation/avcapturedevice/1624613-authorizationstatus)
- [installTap(onBus:bufferSize:format:block:) — Apple](https://developer.apple.com/documentation/avfaudio/avaudionode/1387122-installtap)
- [Set aggregate device settings in Audio MIDI Setup (clock source + drift correction) — Apple](https://support.apple.com/guide/audio-midi-setup/set-aggregate-device-settings-ams094c7edb4/mac)
- [Using drift correction to keep aggregate device audio in sync — Rogue Amoeba](https://rogueamoeba.com/support/knowledgebase/?showArticle=Loopback-AggregateDeviceHandling)
- [insidegui/AudioCap — canonical sample (aggregate dict, tap, IOProc)](https://github.com/insidegui/AudioCap)
- [CoreAudio Taps for Dummies — maven.de (note: advises tap-only aggregate; mic-as-subdevice needs explicit mic permission)](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/)
- [makeusabrew/audiotee — Swift CLI process-tap reference](https://github.com/makeusabrew/audiotee)
- [AVAudioEngine sample-rate mismatch on installTap — Apple Developer Forums](https://developer.apple.com/forums/thread/680785)

**One caveat flagged in the sources:** maven.de reports that adding the *tapped output device's input streams* into the aggregate "only confused matters." That refers to tapping a device that itself has inputs — distinct from adding the **mic** as an explicit sub-device. AudioCap's pattern (output as main sub-device + tap) is proven; adding the **mic** sub-device with drift comp is the documented multi-member aggregate behavior, but verify channel layout from `kAudioTapPropertyFormat` at runtime and confirm the mic channels land where you expect in the IOProc buffer before relying on the pan mapping.

---

## eventkit-calendar

I now have all the verified details I need. This is a research task — I'll compile my findings directly as my final response (no plan file needed, since the user wants research output, not a code-change plan). Let me write the comprehensive answer.

# EventKit Calendar Integration on macOS 26 (Darwin 25)

Everything below is verified against Apple's current docs and the iOS 17 / macOS 14 access model (still the current model on macOS 26 — Apple has not changed it since). All APIs are available macOS 14.0+ unless noted, so they are safe on your macOS 26.3 target.

---

## 1. Requesting access

### Framework & store
`import EventKit`. Create **one** `EKEventStore` and keep it alive for the app's lifetime — releasing it invalidates every `EKEvent`/`EKCalendar` it vended.

### The current API (macOS 14+)
`requestAccess(to:completion:)` is **deprecated**. Use the access-split APIs:

- `func requestFullAccessToEvents() async throws -> Bool`  (also a `completion:` variant)
- `func requestWriteOnlyAccessToEvents() async throws -> Bool`

For reading meetings around "now" you need **full access** (write-only cannot read existing events).

### Authorization status enum
`EKEventStore.authorizationStatus(for: .event)` returns `EKAuthorizationStatus`:

| Case | Raw | Notes |
|---|---|---|
| `.notDetermined` | 0 | never asked |
| `.restricted` | 1 | MDM/parental |
| `.denied` | 2 | user said no |
| `.fullAccess` | 3 | macOS 14+ — read+write (**same raw value as legacy `.authorized`**) |
| `.writeOnly` | 4 | macOS 14+ — add-only |
| `.authorized` | 3 | legacy alias, deprecated |

Note the raw-value collision between `.authorized` and `.fullAccess` (both 3) — switch on the enum case, never the raw Int.

### Swift sketch

```swift
import EventKit

@MainActor
final class CalendarAccess {
    let store = EKEventStore()   // single, long-lived instance

    func ensureFullAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return true
        case .notDetermined:
            do { return try await store.requestFullAccessToEvents() }
            catch { return false }
        case .writeOnly, .denied, .restricted, .authorized:
            return false   // .writeOnly can't read; others need Settings change
        @unknown default:
            return false
        }
    }
}
```

### Info.plist & entitlements — sandboxed vs not

**Info.plist (required in BOTH cases):**
```xml
<key>NSCalendarsFullAccessUsageDescription</key>
<string>Recorder names your recording folders after the meeting on your calendar.</string>
```
- `NSCalendarsFullAccessUsageDescription` is the key that pairs with `requestFullAccessToEvents`. Missing it → the request fails / the app crashes on request.
- `NSCalendarsUsageDescription` is the **pre-macOS 14 legacy** key. You do not need it for a macOS 26-only app, but it's harmless to also include for back-compat. (`NSCalendarsWriteOnlyAccessUsageDescription` is only for write-only flows — not relevant to you.)

**Entitlement — `com.apple.security.personal-information.calendars`:**
- **Non-sandboxed personal app (your simplest path): NOT required.** This key is a *sandbox-escape* entitlement. A hardened/notarized or just locally-run unsigned app relies purely on TCC: the Info.plist string + the `requestFullAccessToEvents` call triggers the system prompt, and the grant is tracked in System Settings → Privacy & Security → Calendars.
- **If you ever enable App Sandbox:** add
  ```xml
  <key>com.apple.security.personal-information.calendars</key>
  <true/>
  ```
  (set via Xcode target → Signing & Capabilities → App Sandbox → Calendar). Without it, a sandboxed app cannot reach the calendar even with the Info.plist string.

For a personal, possibly-unsigned, locally-run app: **skip the sandbox, skip the entitlement, just ship the Info.plist string.** One caveat for unsigned apps: TCC keys grants partly on code identity, so if you rebuild with a different/ad-hoc signature the OS may re-prompt or silently lose the prior grant. Signing with a stable (even self-signed/Developer ID) identity makes the grant stick.

---

## 2. Fetching events around "now"

`predicateForEvents(withStart:end:calendars:)` returns an `NSPredicate` matching any event that **overlaps** the window (an event starting before `start` but ending after it is included). `events(matching:)` is **synchronous**, returns `[EKEvent]` in **no guaranteed order**, so sort yourself.

```swift
import EventKit

struct Meeting: Identifiable {
    let id: String          // EKEvent.eventIdentifier
    let title: String
    let start: Date
    let end: Date
}

extension CalendarAccess {
    /// Last couple + next couple of timed meetings in a -2h..+8h window.
    func meetingsAroundNow(back: TimeInterval = -2 * 3600,
                           forward: TimeInterval = 8 * 3600) -> [Meeting] {
        let now = Date()
        let start = now.addingTimeInterval(back)
        let end   = now.addingTimeInterval(forward)

        let predicate = store.predicateForEvents(
            withStart: start, end: end, calendars: nil)  // nil = all calendars

        let events = store.events(matching: predicate)

        var seen = Set<String>()
        return events
            .filter { !$0.isAllDay }                       // drop all-day
            .filter { ($0.title?.isEmpty == false) }       // drop untitled
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
            .compactMap { ev -> Meeting? in
                let key = ev.eventIdentifier ?? "\(ev.title ?? "")|\(ev.startDate?.timeIntervalSince1970 ?? 0)"
                guard seen.insert(key).inserted else { return nil }  // dedup
                guard let s = ev.startDate, let e = ev.endDate else { return nil }
                return Meeting(id: key, title: ev.title ?? "Untitled", start: s, end: e)
            }
    }

    /// The meeting "happening now or most recently started" — best default for naming.
    func currentMeeting() -> Meeting? {
        let now = Date()
        let all = meetingsAroundNow()
        return all.last { $0.start <= now && $0.end >= now }   // in progress
            ?? all.last { $0.start <= now }                     // most recent started
            ?? all.first                                        // else next upcoming
    }
}
```

Notes:
- **All-day events**: filtered via `EKEvent.isAllDay`. (They also have timezone-sensitive boundaries, so excluding them avoids window-edge surprises.)
- **Dedup**: recurring/synced calendars can surface duplicates; dedup on `eventIdentifier` (falls back to title+start). For recurrence-instance precision use `calendarItemIdentifier`/occurrence date, but for naming this is sufficient.
- `events(matching:)` can block briefly on large calendars — call off the main thread if you notice hitches, then hop back to `@MainActor` for UI.

---

## 3. Mapping an event to a folder-name suffix

Target path: `~/Documents/Recordings/{YYYY-M-D}-{HHMM}[-{meeting}]/audio.ogg`. Sanitize the title for HFS+/APFS (forbid `/` and `:`, strip control chars, collapse whitespace, cap length).

```swift
import Foundation

func sanitizedSuffix(from title: String, maxLength: Int = 40) -> String {
    // ":" shows as "/" in Finder and "/" is the path separator — both illegal.
    let illegal = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        .union(.controlCharacters)
    let cleaned = title
        .components(separatedBy: illegal).joined(separator: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let collapsed = cleaned.replacingOccurrences(of: " ", with: "-")
    let truncated = String(collapsed.prefix(maxLength))
        .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
    return truncated.isEmpty ? "meeting" : truncated
}

func recordingFolderURL(meeting: Meeting?, at date: Date = Date()) -> URL {
    let cal = Calendar.current
    let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let datePart = String(format: "%04d-%d-%d", c.year!, c.month!, c.day!)   // 2026-6-2
    let timePart = String(format: "%02d%02d", c.hour!, c.minute!)            // 1430

    var name = "\(datePart)-\(timePart)"
    if let m = meeting { name += "-\(sanitizedSuffix(from: m.title))" }

    let base = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/Recordings", isDirectory: true)
    return base.appendingPathComponent(name, isDirectory: true)
}
```
(Avoid a leading dot in the folder name — it would hide it in Finder; the trim above handles that.)

---

## 4. Detecting scheduled end + gaps/breaks

EventKit has **no callback** for "a meeting's end time arrived." You schedule your own timer from `EKEvent.endDate`. For your recorder, the robust pattern is a single repeating tick (e.g. every 30s) that compares `Date()` against the cached current meeting's `endDate`, plus a notification observer for live calendar edits.

### Has the scheduled end passed?
```swift
extension Meeting {
    var hasEnded: Bool { Date() >= end }
    func endsWithin(_ seconds: TimeInterval) -> Bool {
        let r = end.timeIntervalSinceNow
        return r > 0 && r <= seconds
    }
}
```

### Fire a notification when end passes (one-shot Timer)
```swift
func scheduleEndNotification(for meeting: Meeting,
                             fire: @escaping () -> Void) -> Timer? {
    let delay = meeting.end.timeIntervalSinceNow
    guard delay > 0 else { fire(); return nil }
    let t = Timer(fire: meeting.end, interval: 0, repeats: false) { _ in fire() }
    RunLoop.main.add(t, forMode: .common)
    return t
}
```
Wall-clock `Timer` is fine for foreground notifications; it won't fire reliably during sleep, so on wake re-check `hasEnded` against `Date()`. For a menu-bar app you'd typically use a `UNUserNotificationCenter` request (needs `NSUserNotificationsUsageDescription` is *not* required, but the app must be signed/notarized for `UNUserNotificationCenter` to deliver reliably) or a simpler in-app `NSAlert`/menu badge.

### Detect a scheduled gap/break between consecutive meetings
Sort by start, then look at the gap between meeting *i*'s `end` and meeting *i+1*'s `start`. Note overlapping/back-to-back meetings produce ≤0 gaps.

```swift
struct Gap { let after: Meeting; let before: Meeting; let length: TimeInterval }

func gaps(in meetings: [Meeting], minLength: TimeInterval = 5 * 60) -> [Gap] {
    let sorted = meetings.sorted { $0.start < $1.start }
    var result: [Gap] = []
    for (a, b) in zip(sorted, sorted.dropFirst()) {
        let length = b.start.timeIntervalSince(a.end)
        if length >= minLength {
            result.append(Gap(after: a, before: b, length: length))
        }
    }
    return result
}

/// "Are we in a scheduled break right now?" — useful for auto-stop prompts.
func inScheduledBreakNow(_ meetings: [Meeting], minLength: TimeInterval = 5*60) -> Bool {
    let now = Date()
    return gaps(in: meetings, minLength: minLength)
        .contains { now >= $0.after.end && now < $0.before.start }
}
```

### React to external calendar edits
The store posts `Notification.Name.EKEventStoreChanged` when calendar data changes anywhere on the system. Re-fetch (predicates/events can go stale) and reset timers:
```swift
NotificationCenter.default.addObserver(
    forName: .EKEventStoreChanged, object: store, queue: .main) { _ in
    // events(matching:) results may now be stale — refetch and reschedule.
}
```

---

## Sources

- [EKEventStore.requestFullAccessToEvents](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoevents(completion:)) — macOS 14+ full-access request API
- [Accessing the event store](https://developer.apple.com/documentation/eventkit/accessing-the-event-store) — access steps, full vs write-only
- [EKAuthorizationStatus](https://developer.apple.com/documentation/EventKit/EKAuthorizationStatus) / [.fullAccess](https://developer.apple.com/documentation/eventkit/ekauthorizationstatus/fullaccess?language=objc) / [.writeOnly](https://developer.apple.com/documentation/eventkit/ekauthorizationstatus/writeonly) — enum cases & raw values
- [predicateForEvents(withStart:end:calendars:)](https://developer.apple.com/documentation/eventkit/ekeventstore/predicateforevents(withstart:end:calendars:)) — overlap semantics, returns NSPredicate
- [NSCalendarsFullAccessUsageDescription](https://developer.apple.com/documentation/bundleresources/information-property-list/nscalendarsfullaccessusagedescription) — Info.plist key
- [Calendars entitlement (com.apple.security.personal-information.calendars)](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.personal-information.calendars) — sandbox-only entitlement
- [What are app entitlements, and what do they do? — Eclectic Light](https://eclecticlight.co/2025/03/24/what-are-app-entitlements-and-what-do-they-do/) — confirms privacy entitlements are sandbox-only; non-sandboxed apps rely on TCC + attribution chain
- [Discover Calendar and EventKit — WWDC23 (10052)](https://developer.apple.com/videos/play/wwdc2023/10052/) — the three access levels, reuse one store, full-access prompts denied more often
- [Accessing Calendar using EventKit and EventKitUI](https://developer.apple.com/documentation/eventkit/accessing-calendar-using-eventkit-and-eventkitui) — sample code
- [Getting access to the user's calendar — Create with Swift](https://www.createwithswift.com/getting-access-to-the-users-calendar/) — status-switch pattern

**Key takeaways:** For your non-sandboxed personal app you need only `import EventKit`, a single long-lived `EKEventStore`, the `NSCalendarsFullAccessUsageDescription` Info.plist string, and a `requestFullAccessToEvents()` call — **no entitlement**. Fetch via `predicateForEvents(withStart:end:calendars:)` (it matches overlapping events), filter `isAllDay`, sort by `startDate`, dedup on `eventIdentifier`. EventKit gives you no end-of-meeting callback — drive it yourself from `endDate` with a `Timer`, observe `.EKEventStoreChanged` for live edits, and compute gaps from sorted end→next-start deltas.

---

## menubar-app-shell

I now have everything verified. Returning the comprehensive answer.

---

# SwiftUI Menu-Bar Shell, Lifecycle, Auto-Stop & Notifications — macOS 26

Everything below is current for macOS 26 (Darwin 25), Xcode 26.4, Swift 6.3. APIs cited are version-agnostic landing pages on Apple's side, so I note the introducing OS for each.

---

## 1. The menu-bar shell: `MenuBarExtra` + activation policy

### Scene + style

`MenuBarExtra` is a SwiftUI `Scene`, macOS 13+ only. For your panel (record/pause/save/trash buttons + a live list of meetings) you **must** use `.menuBarExtraStyle(.window)` — the default `.menu` style strips button styles, ignores images, and only renders text/buttons/dividers. The `.window` style renders an arbitrary SwiftUI view in a popover-like panel.

```swift
import SwiftUI

@main
struct RecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = RecorderModel()          // @Observable, app-level

    var body: some Scene {
        MenuBarExtra {
            RecorderPanel()
                .environment(model)
                .frame(width: 340)                       // fix width; height grows to content
        } label: {
            // Icon reflects state. Use a state-driven SF Symbol.
            Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle")
                .symbolRenderingMode(.palette)
        }
        .menuBarExtraStyle(.window)

        // Optional Settings scene (see caveat in §1.4)
        Settings { SettingsView().environment(model) }
    }
}
```

**Initializer caveats** (verified, still true in Xcode 26):
- There is an `isInserted: Binding<Bool>` initializer to show/hide the status item — useful if you want a "hide from menu bar" toggle.
- There is **no** first-party API to programmatically open/close the panel, read its presentation state, disable the item, or get the underlying `NSStatusItem`/`NSWindow`. If you need to *programmatically* dismiss the panel (e.g., after "Save") or want a right-click Quit menu, you need the community package [`MenuBarExtraAccess`](https://github.com/orchetect/MenuBarExtraAccess) which surfaces an `isPresented` binding and the `NSStatusItem`.
- With `.menu` style specifically, the open menu blocks the runloop — observing `isPresented` won't work. Another reason to use `.window`.

Source: [MenuBarExtra — Apple](https://developer.apple.com/documentation/swiftui/menubarextra), [MenuBarExtraStyle — Apple](https://developer.apple.com/documentation/swiftui/menubarextrastyle), [Build a macOS menu bar utility in SwiftUI — Nil Coalescing](https://nilcoalescing.com/blog/BuildAMacOSMenuBarUtilityInSwiftUI/), [Cindori: Hands-on MenuBarExtra](https://cindori.com/developer/hands-on-menu-bar).

### Hide the Dock icon

Two equivalent levers — pick **one**, use the Info.plist key for simplicity:

1. **Static (recommended for your case):** set `Application is agent (UIElement)` = `YES` (`LSUIElement` = `true`) in Info.plist. No Dock icon, no app-switcher entry, ever. Since there's no Dock icon, you must provide a Quit button inside the panel (`Button("Quit") { NSApplication.shared.terminate(nil) }`).
2. **Dynamic:** `NSApp.setActivationPolicy(.accessory)` at launch (in `applicationDidFinishLaunching`). Useful only if you want to flip to `.regular` (Dock visible) when showing a real window.

Note: an accessory/`LSUIElement` app is not "active" in the normal sense, which makes opening a **Settings** window flaky. `SettingsLink` and `@Environment(\.openSettings)` (macOS 14+) are documented but unreliable from a menu-bar app — the known 2025 workaround is to temporarily `setActivationPolicy(.regular)`, `NSApp.activate()`, open the window, then flip back to `.accessory`, plus declare a hidden `Window` scene *before* the `Settings` scene. For a personal app, prefer putting settings **inside the popover panel** and skip the Settings scene entirely.

Source: [Steinberger: Showing Settings from menu bar items (2025)](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items), [Hiding your app's icon from the Dock — buresdv](https://buresdv.substack.com/p/swift-protip-hiding-your-apps-icon), [toggle-macos-dock-icon (GitHub)](https://github.com/artlasovsky/toggle-macos-dock-icon).

### App-level state model (`@Observable`)

Use the macOS 14+ Observation framework `@Observable` macro rather than `ObservableObject`/`@Published`. It tracks per-property access (less invalidation), works cleanly with SwiftUI, and avoids `Published` boilerplate. Inject via `.environment(model)` / read via `@Environment(RecorderModel.self)`.

Because you'll touch `AVAudioEngine` from audio threads, isolate the model to `@MainActor` and hop to it when publishing levels (see §3). Engines themselves are not actors — keep them as plain properties and call their thread-safe methods.

```swift
import Observation
import AVFoundation

@MainActor
@Observable
final class RecorderModel {
    enum State { case idle, recording, paused }
    var state: State = .idle
    var isRecording: Bool { state == .recording }

    // Live meter values, hard-panned sources
    var micLevel: Float = 0          // 0...1 (mapped from dBFS) — right channel
    var desktopLevel: Float = 0      // 0...1                       — left channel

    var currentSession: RecordingSession?
    var upcomingMeetings: [Meeting] = []     // from EventKit, see §2/§5

    // Engines / writers are owned here but are NOT @Observable-tracked usefully
    @ObservationIgnored var micEngine: AVAudioEngine?
    @ObservationIgnored var systemTap: AnyObject?     // your CATap/ScreenCaptureKit object
    @ObservationIgnored var micFile: AVAudioFile?
    @ObservationIgnored var desktopFile: AVAudioFile?
    @ObservationIgnored var silenceClock: SilenceMonitor?
}
```

(Your sibling research topic owns the actual mic + system-audio capture; this model is where both halves dock.)

---

## 2. UserNotifications in a menu-bar app

### The one critical gotcha

**The app must be code-signed for the authorization prompt to appear** — even in local/Debug builds. Unsigned menu-bar apps silently get no prompt and no notifications. For a personal app this means at minimum an ad-hoc / "Sign to Run Locally" / Developer-ID signature with the app bundle's `CFBundleIdentifier` stable. (Notarization is *not* required for notifications, just a valid signature + bundle ID.)

Source: [requestAuthorization — Apple](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:)), [UNUserNotificationCenter — Apple](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter).

### Setup (delegate in an AppDelegate, request at launch)

```swift
import UserNotifications
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self                       // set BEFORE requesting

        // Action button on the notification ("Stop now")
        let stop = UNNotificationAction(identifier: "STOP_RECORDING",
                                        title: "Stop Recording",
                                        options: [.foreground])
        let cat = UNNotificationCategory(identifier: "MEETING_ENDED",
                                         actions: [stop],
                                         intentIdentifiers: [],
                                         options: [])
        center.setNotificationCategories([cat])

        Task {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    // Show the banner even though the accessory app is "foreground/active"
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                willPresent n: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // Click / action tap → focus + stop
    func userNotificationCenter(_ c: UNUserNotificationCenter,
                                didReceive r: UNNotificationResponse) async {
        if r.actionIdentifier == "STOP_RECORDING"
            || r.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                // model.stopAndSave()  — call into your RecorderModel
            }
        }
    }
}
```

### Posting "meeting end passed while still recording"

Schedule a time-based local notification at the meeting's scheduled end. If recording stops before then, cancel it.

```swift
func scheduleMeetingEndAlert(at end: Date, meetingTitle: String, id: String) {
    let center = UNUserNotificationCenter.current()
    let content = UNMutableNotificationContent()
    content.title = "Meeting ended — still recording"
    content.body  = "\(meetingTitle) was scheduled to end. Stop and save?"
    content.categoryIdentifier = "MEETING_ENDED"
    content.interruptionLevel = .timeSensitive          // macOS 12+/iOS 15+

    let interval = max(1, end.timeIntervalSinceNow)
    let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
    center.add(UNNotificationRequest(identifier: "meeting-end-\(id)",
                                     content: content, trigger: trigger))
}

func cancelMeetingEndAlert(id: String) {
    UNUserNotificationCenter.current()
        .removePendingNotificationRequests(withIdentifiers: ["meeting-end-\(id)"])
}
```

Required Info.plist: notifications themselves need **no** usage-description string (only the runtime authorization). For the meeting list/end-time source from Calendar, see §5 (`NSCalendarsFullAccessUsageDescription`, macOS 14+).

Source: [Requesting authorization async/await — Create with Swift](https://www.createwithswift.com/notifications-tutorial-requesting-user-authorization-for-notifications-with-async-await/).

---

## 3. Silence / auto-stop logic (RMS on both channels)

Compute levels **inside the existing capture taps** — do not add separate taps just for metering. You already tap the mic engine and the system-audio source; in each tap closure compute RMS → dBFS for that source. MIC = right, DESKTOP = left.

### Cheap RMS via Accelerate (vDSP)

`installTap(...)` callbacks fire on a high-priority audio thread. Do the math there (it's cheap), then hop to `@MainActor` only to publish the smoothed value.

```swift
import Accelerate
import AVFoundation

func rmsDBFS(_ buffer: AVAudioPCMBuffer) -> Float {
    guard let ch = buffer.floatChannelData else { return -160 }
    var rms: Float = 0
    vDSP_rmsqv(ch[0], 1, &rms, vDSP_Length(buffer.frameLength))   // vectorized RMS
    guard rms > 0 else { return -160 }
    return 20 * log10(rms)                                        // dBFS, ~ -160...0
}
```

Caveats verified for macOS: **install taps off the main thread**, only **one tap per bus**, requested `bufferSize` is a hint (you may get larger buffers), and after an input-device change re-fetch `outputFormat(forBus:)` before re-installing or you crash on a stale format.

Source: [averagePower/peakPower (dBFS def) — Apple](https://developer.apple.com/documentation/avfaudio/avaudiorecorder/1387176-averagepower), [vDSP_rmsqv / Accelerate metering — Better Programming](https://medium.com/better-programming/audio-visualization-in-swift-using-metal-accelerate-part-1-390965c095d7), [AudioKit RMS processing](https://github.com/AudioKit/AudioKit/blob/main/Sources/AudioKit/Audio%20Files/AVAudioPCMBuffer%2BProcessing.swift).

### 5-minute dual-channel silence detector

Track the **most-recent time either channel exceeded a threshold**. If neither channel has crossed the threshold for 5 continuous minutes, auto-stop. Drive it off a low-frequency `Timer` rather than per-buffer to keep it trivial.

```swift
@MainActor
final class SilenceMonitor {
    private let thresholdDB: Float = -50          // tune: -45…-55 dBFS = "silence"
    private let silenceWindow: TimeInterval = 300 // 5 min
    private var lastSoundAt = Date()
    private var ticker: Timer?
    var onAutoStop: (() -> Void)?

    /// Call from each tap (already hopped to main via the model).
    func ingest(micDB: Float, desktopDB: Float) {
        if micDB > thresholdDB || desktopDB > thresholdDB {
            lastSoundAt = Date()
        }
    }

    func start() {
        lastSoundAt = Date()
        ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if Date().timeIntervalSince(self.lastSoundAt) >= self.silenceWindow {
                self.onAutoStop?()
            }
        }
    }
    func stop() { ticker?.invalidate(); ticker = nil }
}
```

For **meeting-relative auto-stop**, schedule a one-shot timer (or reuse the notification's fire time) at `meetingEnd + grace` and call the same stop path. Two independent stop triggers — silence and schedule — both funnel into one `stopAndSave()`.

Map dBFS → 0...1 for the meter views: `level = max(0, (db + 80) / 80)` clamped, guarding for non-finite.

---

## 4. "Save frequently" + pause without tearing down the device

### Continuous write = one `AVAudioFile` per source, written in the tap

`AVAudioFile.write(from:)` flushes each buffer to disk as it's written, so a crash loses at most one buffer (~tens of ms). You keep two raw files (mic.caf + desktop.caf) and merge/pan/encode to `.ogg` on stop via your ffmpeg step — exactly the strategy in the brief.

Write **CAF/PCM** for the raw files (robust to truncation, fast, no encode cost on the audio thread). `audio.ogg` is produced afterward.

```swift
// Setup at record start (off main thread):
let settings: [String: Any] = [
    AVFormatIDKey: kAudioFormatLinearPCM,
    AVSampleRateKey: format.sampleRate,
    AVNumberOfChannelsKey: 1,                    // each source mono; pan happens at merge
    AVLinearPCMBitDepthKey: 32,
    AVLinearPCMIsFloatKey: true,
    AVLinearPCMIsNonInterleaved: false
]
micFile = try AVAudioFile(forWriting: micURL, settings: settings,
                          commonFormat: .pcmFormatFloat32, interleaved: false)

// Inside the mic tap:
micEngine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { buf, _ in
    let db = rmsDBFS(buf)
    if model.state == .recording {               // PAUSE = stop appending, see below
        try? micFile?.write(from: buf)           // flushes per call
    }
    Task { @MainActor in
        model.micLevel = max(0, (db + 80) / 80)
        model.silenceClock?.ingest(micDB: db, desktopDB: model.lastDesktopDB)
    }
}
```

### Pause semantics

**Do not** stop the `AVAudioEngine` or remove taps on pause — that tears down the device, can re-prompt, and can renegotiate the format (crash risk on resume). Instead:

- **Pause:** flip `model.state = .paused`. The tap still fires but the `if state == .recording` guard skips `write(from:)`. The device stays live, the meter keeps moving, no gap/glitch. This produces a *gap* in the file (paused audio is dropped) which is usually what you want for a recorder.
- **Resume:** flip back to `.recording`; writes resume appending to the same `AVAudioFile`.
- **Stop/Save:** stop engine, `removeTap`, set `micFile = nil` / `desktopFile = nil` (closing the files and finalizing), then kick the ffmpeg merge+pan+encode and keep the raw files.

If you ever need pause to truly idle the hardware (battery), use `engine.pause()` (keeps graph/taps intact, just halts render) rather than `engine.stop()` — but the guard approach is simpler and gapless.

`AVAudioFile` write semantics: [AVAudioFile — Apple](https://developer.apple.com/documentation/avfaudio/avaudiofile).

---

## 5. App Sandbox decision for a personal app

**Recommendation: do NOT sandbox.** Distribute as a local / Developer-ID app. This is the simplest robust path and removes all friction for: any mic, system/desktop audio capture (CATap/ScreenCaptureKit), EventKit calendar reads, and arbitrary writes to `~/Documents/Recordings/...` plus shelling out to `/opt/homebrew/bin/ffmpeg`.

Why non-sandboxed is materially simpler here:
- A sandboxed app **cannot exec an arbitrary external binary** like `/opt/homebrew/bin/ffmpeg` (no `com.apple.security.app-sandbox`-compatible way to run it; you'd have to bundle ffmpeg or link libopus/libogg yourself). Non-sandboxed, you just `Process`-launch it.
- Sandboxed file writes need user-selected/`com.apple.security.files.user-selected.read-write` or a security-scoped bookmark; non-sandboxed writes to `~/Documents/Recordings` are unrestricted.

What you still need either way (TCC, governed by the *attribution chain* + Info.plist purpose strings, **independent of sandbox**):
- **Microphone:** `NSMicrophoneUsageDescription` in Info.plist. (Sandboxed-only entitlement equivalent: `com.apple.security.device.audio-input`.)
- **Calendar (meeting list + end times via EventKit):** macOS 14+ requires **`NSCalendarsFullAccessUsageDescription`** and `requestFullAccessToEvents()`. The old `NSCalendarsUsageDescription` + `requestAccess(to:)` is legacy/superseded. Without the new key, TCC refuses before EventKit is reached. (Sandboxed-only equivalent: `com.apple.security.personal-information.calendars`.)
- **Notifications:** valid code signature (see §2) — required regardless of sandbox.

**If you later choose to sandbox** (e.g., for Mac App Store), add these entitlements: `com.apple.security.app-sandbox`, `com.apple.security.device.audio-input`, `com.apple.security.personal-information.calendars`, and either `com.apple.security.files.user-selected.read-write` (with a save-panel/bookmark for the Recordings folder) — and you'd have to replace the ffmpeg subprocess with bundled/linked encoding. The general Apple guidance is "sandbox by default, disable only if there's no other way" — for a personal recorder that shells to ffmpeg, there genuinely isn't, so non-sandboxed is the right call.

Even non-sandboxed, **still sign + (optionally) notarize with Hardened Runtime** so the OS doesn't show scary warnings and so notifications work. Hardened Runtime + the mic entitlement coexist fine.

Source: [Configuring the macOS App Sandbox — Apple](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox), [App Sandbox Entitlement — Apple](https://developer.apple.com/documentation/BundleResources/Entitlements/com.apple.security.app-sandbox), [What app entitlements do — Eclectic Light](https://eclecticlight.co/2025/03/24/what-are-app-entitlements-and-what-do-they-do/), [Playing in the Mac App Sandbox — TrozWare (2026)](https://troz.net/post/2026/playing_mac_sandbox/), [TN3153: EventKit API changes macOS 14 — Apple](https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos), [requestFullAccessToEvents — Apple](https://developer.apple.com/documentation/eventkit/ekeventstore/4162272-requestfullaccesstoevents).

---

## Info.plist / entitlements summary (non-sandboxed personal app)

| Key | Where | Why |
|---|---|---|
| `LSUIElement` = `YES` | Info.plist | Hide Dock icon (agent app) |
| `NSMicrophoneUsageDescription` | Info.plist | Mic TCC prompt |
| `NSCalendarsFullAccessUsageDescription` | Info.plist | EventKit meeting list (macOS 14+) |
| (none for notifications) | — | Runtime authorization only; needs valid signature |
| Hardened Runtime + "Audio Input" | Signing & Capabilities | Lets signed/notarized build use mic |
| No App Sandbox | — | Allows ffmpeg subprocess + free `~/Documents` writes |

## Minimum-OS notes
- `MenuBarExtra` / `.menuBarExtraStyle`: macOS 13+.
- `@Observable` (Observation): macOS 14+.
- `requestFullAccessToEvents()` + `NSCalendarsFullAccessUsageDescription`: macOS 14+ (fall back to `requestAccess(to:)` only if you target <14, which you don't).
- `interruptionLevel = .timeSensitive`: macOS 12+.
- All comfortably satisfied by your macOS 26 target.

## Loose ends worth flagging for the build phase
1. No first-party way to programmatically close the `MenuBarExtra` panel after Save — add [`MenuBarExtraAccess`](https://github.com/orchetect/MenuBarExtraAccess) if you want that polish.
2. Notifications **will silently no-op if the app isn't signed** — wire signing before you test §2.
3. Keep the silence detector's threshold tunable (`-45…-55 dBFS`); desktop-audio noise floors vary a lot by output device.

**Relevant authoritative URLs** are inline per section above; the load-bearing ones: [MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra), [MenuBarExtraStyle](https://developer.apple.com/documentation/swiftui/menubarextrastyle), [requestAuthorization](https://developer.apple.com/documentation/usernotifications/unusernotificationcenter/requestauthorization(options:completionhandler:)), [TN3153 EventKit changes](https://developer.apple.com/documentation/technotes/tn3153-adopting-api-changes-for-eventkit-in-ios-macos-and-watchos), [Configuring the macOS App Sandbox](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox), [Steinberger on menu-bar Settings (2025)](https://steipete.me/posts/2025/showing-settings-from-macos-menu-bar-items).

---

# Adversarial verification verdicts

## verify:system-audio+aggregate

# Adversarial Verification Verdict

I verified the brief against the actual SDK headers on this machine, the AudioCap source, and current developer/Apple sources. Most of the brief is solid, but it contains **one outright error**, **one doubtful/unproven central claim**, and **misses a confirmed macOS 26 regression** that directly threatens the recommended architecture.

---

## Claim 1 — Process taps work WITHOUT screen-recording permission; TCC service / Info.plist key

**HOLDS, with one factual error you must fix.**

- **API availability — VERIFIED in your SDK.** `/Applications/Xcode.app/.../MacOSX.sdk/.../CoreAudio.framework/Headers/AudioHardwareTapping.h` declares both `AudioHardwareCreateProcessTap` and `AudioHardwareDestroyProcessTap` as `API_AVAILABLE(macos(14.2)) API_UNAVAILABLE(ios, watchos, tvos)`. **No `API_DEPRECATED` marker** anywhere — the brief's "not deprecated" claim is correct. The 14.2-vs-14.4 nuance is right: header gate is 14.2; Apple's docs/sample and broad usability landed with 14.4 (AudioCap README literally says "With macOS 14.4..."). Moot for your 26.3 target.
- **Permission service — VERIFIED.** AudioCap calls `TCCAccessRequest("kTCCServiceAudioCapture", ...)` and `TCCAccessPreflight("kTCCServiceAudioCapture", ...)`, dlsym'd as private SPI behind the pattern the brief describes. So `kTCCServiceAudioCapture` + `NSAudioCaptureUsageDescription` (not in the Xcode dropdown — type it manually) is correct, and **no Screen Recording permission is required**. The pre-flight-via-private-SPI claim is accurate.
- **ERROR — the indicator is the PURPLE dot, not orange.** The brief says the tap shows "the orange microphone/audio indicator." That is wrong. A Core Audio tap of system output triggers the **purple** privacy dot (the "system audio / screen recording" category, present since Sonoma), per the maven.de author who migrated to taps ("a less obnoxious purple dot compared to the orange microphone blob") and corroborated by general macOS indicator docs. The **orange** mic dot appears only if the *tapped device itself has input streams* — in which case you *also* need mic permission (maven.de: "you will _in addition_ still need microphone access to tap that device"). For a clean global output tap you get the purple dot and audio-only consent. This matters for your "less alarming than SCK" argument: it's still purple, same color SCK's screen-recording uses, though it maps to "System Audio Recording Only" in Settings, which is the accurate, lighter permission.
- **Working reference impl — VERIFIED.** `insidegui/AudioCap` is real and current (`stereoMixdownOfProcesses:`, aggregate-with-tap, IO proc, AVAudioFile, TCC SPI probe). Apple's sample "Capturing system audio with Core Audio taps" exists at the cited URL.

---

## Claim 2 — One aggregate device with BOTH a tap AND the mic, driven by one IOProc on one clock

**DOUBTFUL / UNPROVEN — this is the weakest claim in the package, and it's the one the *sync brief* recommends as primary.**

- The canonical reference does **not** do this. AudioCap's aggregate `kAudioAggregateDeviceSubDeviceListKey` contains **only the output device UID**; the mic is never a sub-device. The tap rides in `kAudioAggregateDeviceTapListKey`. No part of the canonical, working code combines a hardware mic and a process tap in one aggregate.
- The one source that tried adding an input device reported it **"only confused matters"** and forced extra mic permission (maven.de). The sync brief's caveat correctly notes this was about the *tapped output device's own input streams*, not an explicit mic sub-device — but that distinction is **the author's untested hope, not verified behavior**. I found no authoritative source demonstrating a tap + explicit-mic aggregate working cleanly with predictable channel layout.
- The SDK keys all check out (`kAudioAggregateDeviceSubDeviceListKey` = `"subdevices"`, `kAudioSubDeviceUIDKey`, `kAudioSubTapUIDKey`, `kAudioSubTapDriftCompensationKey`, `kAudioSubDeviceDriftCompensationKey`, etc.), and multi-member aggregates with drift compensation are a real, documented mechanism. So it's *plausible*. But the drift-comp rule in the sync brief has a subtlety: `kAudioAggregateDeviceMainSubDeviceKey` is literally the string `"master"` and is the **time source**; there is a *separate* `kAudioAggregateDeviceClockDeviceKey` (`"clock"`) that, if present, overrides it. Picking the mic as "master" is fine, but you'd be flying without a reference implementation and would have to confirm channel ordering empirically (the sync brief admits this).

**Bottom line:** the single-aggregate "one clock, zero drift" path is theoretically attractive but **unverified for tap+mic** and contradicts the only proven code. **Two separate captures + post-merge is the pragmatic, reference-backed path** — which is what Approach A's recommendation #4 actually advocates, in tension with the sync brief's "do NOT run two engines" headline. Drift over a long meeting is real, but it's a solvable post-merge resample, and your data-loss/crash-safety goal is *better* served by two independent files than by one IOProc whose failure loses both.

---

## Claim 3 — macOS 26-specific regressions

**The brief UNDER-states this. There is a confirmed, serious Tahoe regression hitting exactly this API.**

- **Apple Developer Forums thread 825780 (the one the brief cites)** documents: `AudioHardwareCreateProcessTap` + aggregate **delivers all-zero PCM buffers after extended uptime** while audio is audibly playing. IOProc keeps firing with normal cadence/timestamps; samples are silently zeroed. Triggered by sample-rate renegotiation (44.1↔48), Bluetooth state changes (AirPods sleep/wake, same UID), more on MacBook Air. **Only reliable fix: full teardown + rebuild of BOTH the tap and the aggregate** (restarting the IOProc or rebuilding only the aggregate is insufficient). The brief lists this forum URL but frames it as "speculation about deprecation" — the real content is this zero-buffer regression, which is far more actionable.
- **Rogue Amoeba (2025-11-04):** 26.0 introduced capture failures (FaceTime/Phone audio; secondary-output sample-rate mismatch); fixed in **26.1**. They recommend **26.1+**. You're on 26.3, good — but community reports say the zero-buffer tap issue persists for some users through 26.3/26.4.x.

**Implication:** whatever architecture you pick, you **must** add a tap watchdog — detect "RMS ≈ 0 for N seconds while `kAudioDevicePropertyDeviceIsRunningSomewhere`/output is active" and auto-rebuild tap+aggregate. This is a *stronger* argument for two-separate-files: a desktop-tap stall then doesn't corrupt or lose your mic recording.

---

## Bonus checks

- **ffmpeg pan mapping — empirically VERIFIED.** I ran Brief A's `join=...map=0.0-FL|1.0-FR` filter with 200 Hz ("desktop") and 1000 Hz ("mic") tones: Left channel carried 200 Hz at −21 dB with the 1000 Hz tone suppressed by −62 dB. **Desktop→Left, Mic→Right is correct and matches your spec** (mic hard RIGHT, desktop hard LEFT). The sync brief's `amerge`+`pan=stereo|c0=c0|c1=c1` variant achieves the same result (desktop is input 0 → L). Your installed ffmpeg is **8.1.1** with `--enable-libopus`/`--enable-libvorbis`, so `.ogg` Opus/Vorbis output is confirmed available. (Brief text said ffmpeg 8.1.1 in one place and "8.1.1"/"8.1.1" — your actual binary is 8.1.1; the "ffmpeg 8.1.1" mention and the stray "8.1.1"/libopus 1.6.1 lib facts all check out.)
- **`CATapDescription` initializers, `bundleIDs`/`processRestoreEnabled` @ `macos(26.0)`, `kAudioTapPropertyFormat='tfmt'`, `CATapMuteBehavior` enum — all VERIFIED verbatim in your SDK headers.** One nit: the property is `muteBehavior` with getter `isMuted`; the brief's `desc.muteBehavior = .unmuted` is correct.

---

## Safest recommended capture architecture

1. **Desktop:** Core Audio global tap — `CATapDescription(stereoGlobalTapButExcludeProcesses: [])`, `.unmuted`, private — wrapped in a **tap-only** aggregate (output device as `"master"`, tap in tap-list, drift comp on). Exactly the AudioCap pattern. Use `bundleIDs` (26.0) only if you later want to exclude your own app.
2. **Mic:** capture **separately** via `AVAudioEngine.inputNode.installTap` (derive format from `inputFormat(forBus:0)`, never hardcode 44100). `kTCCServiceMicrophone` + `NSMicrophoneUsageDescription`.
3. **Two raw `.caf` Float32 files**, written per-callback (frequent flush, crash-resilient). Capture each stream's first-buffer `mHostTime` for alignment.
4. **Watchdog** on the tap for the 26.x zero-buffer regression: RMS-zero-while-running → teardown+rebuild tap+aggregate.
5. **On stop:** ffmpeg merge with desktop→L, mic→R, resample to common rate, `-c:a libopus -b:a 96k output.ogg`. Add `-itsoffset` from the host-time delta if needed. Keep the raw files.

Do **not** adopt the single tap+mic aggregate as primary: it's unproven, contradicts the reference code, and couples two failure-prone streams (worse for your data-loss goal). Treat "one clock via aggregate" as an experiment to validate empirically, not the default.

Sources:
- [AudioCap (insidegui)](https://github.com/insidegui/AudioCap)
- [CoreAudio Taps for Dummies — maven.de](https://www.maven.de/2025/04/coreaudio-taps-for-dummies/)
- [AudioTee write-up — Strongly Typed](https://stronglytyped.uk/articles/audiotee-capture-system-audio-output-macos)
- [Apple — Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [Apple Developer Forums — AudioHardwareCreateProcessTap zero buffers (thread 825780)](https://developer.apple.com/forums/thread/825780)
- [Rogue Amoeba — macOS 26 Tahoe audio bug fixes](https://weblog.rogueamoeba.com/2025/11/04/macos-26-tahoe-includes-important-audio-related-bug-fixes/)
- [BGR — what the purple dot means](https://www.bgr.com/2141159/what-purple-dot-on-macbook-screen-is-for/)

---

## verify:ogg-path

# Adversarial verification verdict — the .ogg encoding brief

I re-ran every load-bearing command against your actual environment (ffmpeg 8.1.1 at `/opt/homebrew/bin/ffmpeg`). Verdicts below, with the empirical evidence.

## Q1 — Is the pan/encode command correct? — **HOLDS, with two corrections**

**Channel routing: CONFIRMED correct.** The brief's primary command works exactly as claimed:

```bash
/opt/homebrew/bin/ffmpeg -y -i desktop.caf -i mic.caf \
  -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[a]" \
  -map "[a]" -c:a libopus -b:a 96k -application audio audio.ogg
```

I generated a 440 Hz desktop tone + 880 Hz mic tone, encoded, decoded back, and measured per-channel band energy:
- LEFT channel: 440 Hz (desktop) = −21.1 dB, 880 Hz = −56.7 dB → **LEFT = desktop** ✓
- RIGHT channel: 440 Hz = −58.9 dB, 880 Hz (mic) = −23.3 dB → **RIGHT = mic** ✓

~35 dB separation. With `-i desktop` first and `-i mic` second, `map=0.0-FL|1.0-FR` puts **desktop hard-left, mic hard-right** — matching your spec. The input *index* (not filename) binds the channel, so input order matters. The `amerge,pan` equivalent gives identical routing (verified). Output is `codec_name=opus, channels=2, channel_layout=stereo` and **macOS plays it natively** (`afinfo` reports `2 ch, opus, Channel layout: Stereo (L R)`).

`-c:a libopus` is present and produces a playable Opus-in-Ogg. **HOLDS.**

**CORRECTION 1 — extension `.opus` vs `.ogg`.** Per Xiph (the authoritative source, https://wiki.xiph.org/index.php/MIMETypesCodecs): `.opus` is the *designated* extension for Opus; `.ogg` is associated with **Vorbis**, `.oga` for general Ogg audio. Opus-in-`.ogg` is technically valid and plays fine (I verified), but the brief's "`.ogg` is fine" understates that you're using a non-canonical extension. Since you explicitly asked for `.ogg`, it's acceptable — just know some strict players/tools key off the extension. MIME for both is `audio/ogg`.

**CORRECTION 2 — Vorbis is NOT actually available (brief is wrong here).** The brief's footer claims libvorbis is usable and lists a `vorbis` encoder. But **`-c:a libvorbis` FAILS** on your ffmpeg: `Unknown encoder 'libvorbis'`. Your build config is `--enable-libopus` but has **no `--enable-libvorbis`** (confirmed from the `-version` line). Only the *experimental native* `vorbis` encoder works, and it needs `-strict -2` (lower quality). So **Opus is the only good codec for `.ogg` on this machine** — which is fine, Opus is the better choice anyway.

**GOTCHA — mismatched lengths, CONFIRMED and reinforced.** `join` truncates to the *shortest* input (5s + 3s → 3.006s); `amerge` does the same. The fix is the brief's `apad` + `-t <longest>`:

```bash
LONGEST=$(...ffprobe max of the two durations...)
/opt/homebrew/bin/ffmpeg -y -i desktop.caf -i mic.caf \
  -filter_complex "[0:a]apad[d];[1:a]apad[m];[d][m]join=inputs=2:channel_layout=stereo:map=0.0-FL|1.0-FR[a]" \
  -map "[a]" -t "$LONGEST" -c:a libopus -b:a 96k audio.ogg
```
Verified: produces 5.006s. **But the `-t` is MANDATORY, not optional** — `apad` makes both streams infinite, so `apad` + `-shortest` *without* `-t` ran toward ~2384 seconds before I killed it. Compute `LONGEST` from `ffprobe -show_entries format=duration` of the two raw files. (The brief's `-shortest -t <longest>` combo also works; `-t` alone is cleaner.) Encoder options all verified: `-application audio|voip|lowdelay`, `-frame_duration` default 20ms, VBR on by default.

## Q2 — Reliability / distribution — **HOLDS**

- Depending on `/opt/homebrew/bin/ffmpeg` is **fine for a personal app**. Zero concern.
- **What breaks if moved:** a machine without Homebrew ffmpeg at that path → your `Process` launch fails (no fallback). Guard with a `FileManager.fileExists` check and surface a clear error; keep raw files so the merge can be re-run later.
- **GPL caveat HOLDS:** your build is `--enable-gpl --enable-version3` (pulls x264/x265). Irrelevant unless you *redistribute the binary*, at which point GPLv3 obligations attach. For signed/notarized distribution you'd bundle either a minimal LGPL ffmpeg (`--disable-gpl --enable-libopus`) or link libopus/libogg directly.
- **SwiftPM systemLibrary route (Path 2):** real and viable (libopus.a/libogg.a are arm64-present), but **Xcode app targets ignore pkg-config** — you must manually add `/opt/homebrew/include` to Header Search Paths, `/opt/homebrew/lib` to Library Search Paths, and `-lopus -logg` to Other Linker Flags. Moderate effort, and it buys you nothing for a personal app *except* page-level flush during live encoding (see Q3).

## Q3 — Does "merge-on-stop" lose the frequent-flush guarantee for the FINAL ogg? — **DOUBTFUL as stated; acceptable with a caveat**

Yes: the `.ogg` is a **one-shot post-process that only exists after stop**. The frequent-flush durability comes entirely from the **live writer in front of it**, not from ffmpeg. So:
- Raw per-source files = safe continuously (if you flush/`fsync` them as you write).
- The `.ogg` = only after a clean stop + successful ffmpeg run.

**This is acceptable ONLY if you keep the raw files** (which is your stated strategy — good). If the app crashes mid-recording, you lose the ogg but keep recoverable raw audio. Do **not** stream-encode live to ogg unless you go Path 2 (libopus + manual `ogg_stream_flush` + `fsync`), which is the one place Path 2 genuinely wins.

## Gap the brief never addresses

The brief verifies the *encode* step thoroughly but **never explains how to capture desktop/system audio** — the actual hard part of your app. For macOS 26 you need either:
- **CoreAudio process taps**: `AudioHardwareCreateProcessTap` + `CATapDescription` + `AudioHardwareCreateAggregateDevice` (macOS 14.2/14.4+), reading via an `AudioDeviceIOProc`. Requires TCC **Audio Recording** permission. Known issue to watch: zero-filled buffers on long sessions reported by some devs. Apple docs: https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
- **ScreenCaptureKit** `SCStream` with `SCStreamConfiguration.capturesAudio = true` (macOS 13+), 48kHz/2ch. Requires Screen Recording TCC. Long-session `EXC_BAD_ACCESS` crash reports exist. https://developer.apple.com/documentation/screencapturekit/
- Mic: `AVAudioEngine`/`AVCaptureDevice` + `NSMicrophoneUsageDescription`. AVAssetWriter (https://developer.apple.com/documentation/avfoundation/avassetwriter) writes `.caf` incrementally for the durable raw layer.

## Safest recommended path + fallback

**Primary:** live-capture each source to its own `.caf` (CoreAudio tap for desktop, AVAudioEngine for mic) with periodic flush → on stop, `ffprobe` the two durations, take the max, run the `apad + join=...map=0.0-FL|1.0-FR + -t <longest> + libopus` command → `audio.ogg`. **Keep the raw `.caf` files.** Consider naming the output `audio.opus` if you want strict-correct labeling, but `.ogg` works.

**Fallback:** if ffmpeg is unavailable or ogg becomes a problem, mix to a stereo `AVAssetWriterInput` → AAC `.m4a`, fully native, no external binary.

Sources: https://ffmpeg.org/ffmpeg-filters.html · https://wiki.xiph.org/index.php/MIMETypesCodecs · https://opus-codec.org/license/ · https://datatracker.ietf.org/doc/html/rfc7845 · https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps · https://developer.apple.com/documentation/screencapturekit/ · https://developer.apple.com/documentation/avfoundation/avassetwriter

---

