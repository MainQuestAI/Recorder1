#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recorder1-integrity.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
swiftc -o "$WORK_DIR/probe" \
  Sources/Recorder/AudioQualityAnalyzer.swift \
  Sources/Recorder/AudioDeviceCatalog.swift \
  Sources/Recorder/SystemAudioCaptureMetadata.swift \
  Sources/Recorder/Shared.swift \
  scripts/verify-audio-integrity.swift
"$WORK_DIR/probe" "$@"
