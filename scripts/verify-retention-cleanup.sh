#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recorder1-retention-cleanup.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

PROBE_BIN="$WORK_DIR/retention-cleanup-probe"

swiftc \
  -o "$PROBE_BIN" \
  Sources/Recorder/AudioDeviceCatalog.swift \
  Sources/Recorder/AudioQualityAnalyzer.swift \
  Sources/Recorder/SystemAudioCaptureMetadata.swift \
  Sources/Recorder/RecordingRetentionPolicy.swift \
  Sources/Recorder/RecordingCleanup.swift \
  Sources/Recorder/Shared.swift \
  Sources/Recorder/RecordingsLibrary.swift \
  Sources/Recorder/FeishuUploadJob.swift \
  Sources/Recorder/UploadStatusStore.swift \
  scripts/verify-retention-cleanup.swift

"$PROBE_BIN"
