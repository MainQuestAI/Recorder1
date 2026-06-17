# Changelog

All notable Recorder1 changes will be documented in this file.

The format follows the spirit of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses human-readable release notes rather than strict semantic versioning while it is in MVP stage.

## Unreleased

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
