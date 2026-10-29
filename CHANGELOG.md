# Changelog

All notable Recorder1 changes will be documented in this file.

The format follows the spirit of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses human-readable release notes rather than strict semantic versioning while it is in MVP stage.

## 1.0.2 (2026-10-29)

### Fixed

- Capture microphones through an input-only session so playback route changes do not rebuild a microphone playback unit. Keep explicit input selection, follow default input changes, and bound stalled-input recovery.
- Preserve system audio timestamps through silent output periods and rate changes, include trailing silence, and compare aligned track endpoints for integrity checks.
- Preserve the full microphone sample timestamp gap with bounded silence writes, keep pause/resume aligned, and record capture gaps and device changes. Missing audio still requires upload review.
- Show microphone capture problems in the integrity warning instead of always suggesting system audio is missing.
- Include the Calendar entitlement in signed builds, gate queries on full access, show authorization failures, and use one refreshed snapshot for the meeting list and recording title.

## Unreleased

### Fixed

- Keep development app bundles in a non-indexed build directory to prevent duplicate Recorder1 entries beside the installed app.
- Keep system audio taps running through silence; bound callback-stall recovery instead of repeatedly rebuilding on quiet PCM.
- Recover microphone capture after audio-engine configuration changes, resample rate changes, and preserve short capture gaps in both tracks.
- Require recording review for sparse system audio, capture errors, analysis failures, and mismatched track durations, including library uploads and retries.
- Resume Feishu uploads from durable file/Minute checkpoints, retry known transient failures with a bounded backoff, and stop replaying creation requests whose outcome is unknown.
- Run the native Feishu CLI directly, bypass inherited proxy settings, and terminate timed-out uploads.

### Added

- macOS menu-bar recorder derived from upstream `tobi/recorder`.
- Simultaneous system audio and microphone capture.
- Stereo `audio.m4a` mix with system audio on the left channel and microphone audio on the right channel.
- Feishu upload flow through user-installed `lark-cli`.
- Feishu Minutes creation and optional notes artifact fetching.
- Upload retry that reuses the existing `audio.m4a`.
- Local `metadata.json`, `upload.log`, `feishu_minutes.json`, transcript, and summary outputs.
- Capture integrity guard for silent system-audio cases.
- System-audio fallback and diagnostic commands.
- Microphone input device selection.
- Chinese and English UI text.
- Uploaded-recording retention cleanup.
- Open-source documentation, privacy, security, contribution, and CI scaffolding.

### Removed

- Gemini transcription user flow from the upstream project.
- Gemini API key settings.
- Gemini diarization prompt.
