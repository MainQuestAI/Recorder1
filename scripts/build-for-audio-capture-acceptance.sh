#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RUN_MATRIX=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --diagnose-system-audio-matrix|--run-matrix)
      RUN_MATRIX=true
      shift
      ;;
    *)
      printf 'usage: CODESIGN_IDENTITY="Apple Development: ..." %s [--diagnose-system-audio-matrix]\n' "$0" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  printf 'FAIL CODESIGN_IDENTITY is required for audio-capture acceptance builds.\n' >&2
  exit 1
fi

APP="MeetingCapture.app"
REPORT="signing-report.txt"

printf '==> building signed acceptance app\n'
if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
  CODESIGN_IDENTITY="$CODESIGN_IDENTITY" CODESIGN_KEYCHAIN="$CODESIGN_KEYCHAIN" ./build.sh
else
  CODESIGN_IDENTITY="$CODESIGN_IDENTITY" ./build.sh
fi

{
  printf 'Meeting Capture signing report\n'
  printf 'generated_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'codesign_identity=%s\n' "$CODESIGN_IDENTITY"
  if [[ -n "${CODESIGN_KEYCHAIN:-}" ]]; then
    printf 'codesign_keychain=%s\n' "$CODESIGN_KEYCHAIN"
  fi

  printf '\n==> codesign --verify --deep --strict --verbose=4 %s\n' "$APP"
  codesign --verify --deep --strict --verbose=4 "$APP"

  printf '\n==> codesign -dv --verbose=4 %s\n' "$APP"
  codesign -dv --verbose=4 "$APP"

  printf '\n==> codesign -dr - %s\n' "$APP"
  codesign -dr - "$APP"

  printf '\n==> codesign --display --entitlements :- %s\n' "$APP"
  codesign --display --entitlements :- "$APP"
} >"$REPORT" 2>&1

if grep -q 'Signature=adhoc' "$REPORT"; then
  printf 'FAIL acceptance build is ad-hoc signed. See %s\n' "$REPORT" >&2
  exit 1
fi

printf 'PASS signing report written: %s\n' "$REPORT"

if [[ "$RUN_MATRIX" == true ]]; then
  MATRIX_JSON="/tmp/meeting-capture-system-audio-matrix.json"
  printf '==> running system audio matrix\n'
  "$APP/Contents/MacOS/Recorder" \
    --diagnose-system-audio-matrix \
    --diagnose-output "$MATRIX_JSON"
  printf 'PASS matrix written: %s\n' "$MATRIX_JSON"
fi
