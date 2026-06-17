#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0
PERMISSIONS_CONFIRMED=false

pass() {
  printf 'PASS %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

warn() {
  printf 'WARN %s\n' "$1"
  WARN_COUNT=$((WARN_COUNT + 1))
}

fail() {
  printf 'FAIL %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

need() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$1 is available"
  else
    fail "$1 is missing"
  fi
}

read_plist_raw() {
  /usr/bin/plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

version_major() {
  printf '%s' "$1" | awk -F. '{print $1}'
}

run_step() {
  local label="$1"
  shift
  printf '\n==> %s\n' "$label"
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

resolve_lark_cli() {
  local candidates=()
  if [[ -n "${LARK_CLI_PATH:-}" ]]; then
    candidates+=("$LARK_CLI_PATH")
  fi
  candidates+=(
    "/opt/homebrew/bin/lark-cli"
    "/usr/local/bin/lark-cli"
    "$HOME/.npm-global/bin/lark-cli"
    "$HOME/.local/bin/lark-cli"
  )
  local from_path
  from_path="$(command -v lark-cli 2>/dev/null || true)"
  if [[ -n "$from_path" ]]; then
    candidates+=("$from_path")
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

printf 'Recorder1 MVP self-check\n'
printf 'Root: %s\n' "$ROOT"

need sw_vers
need xcodebuild
need swift
need codesign
need rg
need sqlite3

MACOS_VERSION="$(sw_vers -productVersion)"
MIN_MACOS="$(read_plist_raw LSMinimumSystemVersion Info.plist)"
if [[ -n "$MIN_MACOS" && "$(version_major "$MACOS_VERSION")" -ge "$(version_major "$MIN_MACOS")" ]]; then
  pass "macOS $MACOS_VERSION satisfies LSMinimumSystemVersion $MIN_MACOS"
else
  fail "macOS $MACOS_VERSION does not satisfy LSMinimumSystemVersion ${MIN_MACOS:-unknown}"
fi

printf 'Xcode: %s\n' "$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
printf 'Swift: %s\n' "$(swift --version | head -n 1)"

run_step "swift build" swift build
run_step "bundle Recorder1.app" ./build.sh

APP="Recorder1.app"
APP_PLIST="$APP/Contents/Info.plist"

if [[ -d "$APP" ]]; then
  pass "$APP exists"
else
  fail "$APP was not created"
fi

if [[ "$(read_plist_raw LSUIElement "$APP_PLIST")" == "true" ]]; then
  pass "menu-bar-only app: LSUIElement=true"
else
  fail "LSUIElement is not true"
fi

if [[ "$(read_plist_raw CFBundleIdentifier "$APP_PLIST")" == "com.dingcheng.MeetingCapture" ]]; then
  pass "bundle id is com.dingcheng.MeetingCapture"
else
  fail "bundle id mismatch"
fi

if [[ -x "$APP/Contents/MacOS/Recorder" ]]; then
  pass "app executable exists"
else
  fail "app executable is missing"
fi

run_step "codesign verify" codesign --verify --deep --strict "$APP"

printf '\n==> macOS permission check\n'
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
if [[ -r "$TCC_DB" ]] && command -v sqlite3 >/dev/null 2>&1; then
  TCC_ROWS="$(sqlite3 "$TCC_DB" "select service || '=' || auth_value from access where client='com.dingcheng.MeetingCapture';" 2>/dev/null || true)"
  MIC_OK=false
  AUDIO_OK=false
  CALENDAR_OK=false
  if printf '%s\n' "$TCC_ROWS" | grep -q '^kTCCServiceMicrophone=2$'; then
    pass "microphone permission is allowed"
    MIC_OK=true
  else
    warn "microphone permission is not confirmed as allowed"
  fi
  if printf '%s\n' "$TCC_ROWS" | grep -q '^kTCCServiceAudioCapture=2$'; then
    pass "system audio capture permission is allowed"
    AUDIO_OK=true
  else
    warn "system audio capture permission is not confirmed as allowed"
  fi
  if printf '%s\n' "$TCC_ROWS" | grep -q '^kTCCServiceCalendar=2$'; then
    pass "calendar permission is allowed"
    CALENDAR_OK=true
  else
    warn "calendar permission is not confirmed as allowed"
  fi
  if [[ "$MIC_OK" == true && "$AUDIO_OK" == true && "$CALENDAR_OK" == true ]]; then
    PERMISSIONS_CONFIRMED=true
  fi
else
  warn "could not read macOS permission database"
fi

printf '\n==> Gemini removal check\n'
if rg -n "Gemini|GEMINI|diarization|GeminiTranscriber" Sources Info.plist Package.swift >/tmp/meeting-capture-gemini-rg.txt 2>/dev/null; then
  cat /tmp/meeting-capture-gemini-rg.txt
  fail "Gemini remnants found"
else
  pass "Gemini remnants not found"
fi

printf '\n==> Feishu CLI check\n'
if LARK_CLI="$(resolve_lark_cli)"; then
  pass "lark-cli resolved: $LARK_CLI"
  "$LARK_CLI" --version || warn "could not print lark-cli version"

  REQUIRED_SCOPES="drive:file:upload minutes:minutes.upload:write vc:note:read minutes:minutes:readonly minutes:minutes.artifacts:read minutes:minutes.transcript:export"
  if "$LARK_CLI" auth check --scope "$REQUIRED_SCOPES" --json >/tmp/meeting-capture-lark-auth.json; then
    pass "required Feishu scopes are available"
  else
    cat /tmp/meeting-capture-lark-auth.json 2>/dev/null || true
    fail "required Feishu scopes are missing or lark-cli is not logged in"
  fi
else
  fail "lark-cli not found"
fi

run_step "failed upload preserves audio and retry succeeds" bash ./scripts/verify-upload-retry.sh

printf '\n==> Local recordings folder check\n'
MEETING_ROOT="$HOME/Documents/Recorder1"
LATEST_AUDIO=""
if [[ -d "$MEETING_ROOT" ]]; then
  pass "$MEETING_ROOT exists"
  LATEST="$(find "$MEETING_ROOT" -maxdepth 1 -type d -name '20*' -print | sort | tail -n 1 || true)"
  if [[ -n "$LATEST" ]]; then
    printf 'Latest recording folder: %s\n' "$LATEST"
    [[ -f "$LATEST/metadata.json" ]] && pass "latest metadata.json exists" || warn "latest metadata.json is missing"
    [[ -f "$LATEST/upload.log" ]] && pass "latest upload.log exists" || warn "latest upload.log is missing"
    if [[ -f "$LATEST/audio.m4a" ]]; then
      pass "latest audio.m4a exists"
      LATEST_AUDIO="$LATEST/audio.m4a"
    else
      warn "latest audio.m4a is missing"
    fi
  else
    warn "no recording folder found yet"
  fi
else
  warn "$MEETING_ROOT does not exist yet"
fi

if [[ -n "$LATEST_AUDIO" ]]; then
  run_step "latest audio is playable stereo m4a" bash ./scripts/analyze-latest-audio.sh 1 --allow-silent-channel
else
  warn "latest audio check skipped because no saved recording exists yet"
fi

printf '\n==> Manual checks still required\n'
if [[ "$PERMISSIONS_CONFIRMED" != true ]]; then
  warn "macOS microphone, system audio, and calendar prompt approval must be confirmed in the app UI"
fi
warn "remote audio capture must be tested in Zoom, Feishu Meeting, Tencent Meeting, Teams, and Google Meet"
warn "AirPods, wired headset, and speaker output routing must be tested"
warn "30-minute continuous recording playback must be tested"

printf '\nSummary: %d passed, %d warning(s), %d failed\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
