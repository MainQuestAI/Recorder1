#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/meeting-capture-upload-retry.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

PROBE_BIN="$WORK_DIR/upload-retry-probe"
FAKE_CLI_BIN="$WORK_DIR/fake-lark-cli"

swiftc \
  -o "$FAKE_CLI_BIN" \
  scripts/fixtures/FakeLarkCLI.swift

swiftc \
  -o "$PROBE_BIN" \
  Sources/Recorder/AudioQualityAnalyzer.swift \
  Sources/Recorder/AudioDeviceCatalog.swift \
  Sources/Recorder/SystemAudioCaptureMetadata.swift \
  Sources/Recorder/Shared.swift \
  Sources/Recorder/RecordingsLibrary.swift \
  Sources/Recorder/CLIProcessRunner.swift \
  Sources/Recorder/FeishuMinutesParser.swift \
  Sources/Recorder/FeishuUploadJob.swift \
  Sources/Recorder/FeishuCLIUploader.swift \
  Sources/Recorder/UploadStatusStore.swift \
  scripts/verify-upload-retry.swift

"$PROBE_BIN" "$WORK_DIR/job" "$FAKE_CLI_BIN"
