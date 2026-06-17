#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MIN_DURATION="${1:-1}"
shift || true
MEETING_ROOT="$HOME/Documents/Recorder1"

if [[ ! -d "$MEETING_ROOT" ]]; then
  echo "FAIL recording folder not found: $MEETING_ROOT" >&2
  exit 1
fi

LATEST_AUDIO="$(find "$MEETING_ROOT" -maxdepth 2 -type f -name 'audio.m4a' -print | sort | tail -n 1)"
if [[ -z "$LATEST_AUDIO" ]]; then
  echo "FAIL no audio.m4a found under $MEETING_ROOT" >&2
  exit 1
fi

swift scripts/analyze-audio.swift "$LATEST_AUDIO" --min-duration "$MIN_DURATION" "$@"
