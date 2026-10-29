#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/recorder1-route-calendar.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
swiftc -o "$WORK_DIR/probe" Sources/Recorder/{AudioTimelineWriter,TimestampedAudioRingBuffer,CalendarAccess,AudioDeviceCatalog,SystemAudioCaptureMetadata,Shared}.swift scripts/verify-route-calendar.swift
"$WORK_DIR/probe"
