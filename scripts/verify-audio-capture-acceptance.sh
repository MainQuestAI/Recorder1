#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP="Recorder1.app"
BIN="$APP/Contents/MacOS/Recorder"
MATRIX_JSON="/tmp/recorder1-system-audio-matrix.json"
ACCEPTANCE_JSON="/tmp/recorder1-audio-capture-acceptance.json"

fail() {
  printf 'FAIL %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'PASS %s\n' "$1"
}

[[ -x "$BIN" ]] || fail "$BIN is missing. Build the app first."
command -v codesign >/dev/null 2>&1 || fail "codesign is missing"
command -v python3 >/dev/null 2>&1 || fail "python3 is missing"

CODESIGN_DISPLAY="$(codesign -dv --verbose=4 "$APP" 2>&1 || true)"
if printf '%s\n' "$CODESIGN_DISPLAY" | grep -q 'Signature=adhoc'; then
  fail "app is ad-hoc signed; run scripts/build-for-audio-capture-acceptance.sh with CODESIGN_IDENTITY"
fi
pass "app is not ad-hoc signed"

printf '\n==> system audio matrix\n'
if "$BIN" --diagnose-system-audio-matrix --diagnose-output "$MATRIX_JSON"; then
  pass "matrix command completed"
else
  printf 'Matrix output: %s\n' "$MATRIX_JSON" >&2
  fail "matrix command did not find a passing defaultOutputDevice probe"
fi

python3 - "$MATRIX_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

passing = [
    p for p in data.get("probes", [])
    if p.get("device_role") == "default_output" and p.get("ok") is True
]
if not passing:
    raise SystemExit("FAIL no defaultOutputDevice probe has ok=true")

print("PASS defaultOutputDevice probe ok=true")
for p in passing:
    print(
        "  tap={tap_kind} include_subdevice={include_subdevice} "
        "input_rms_db={input_rms_db:.1f} input_peak_db={input_peak_db:.1f} "
        "device={output_device_name}".format(**p)
    )
PY

printf '\n==> local recording acceptance\n'
if "$BIN" --diagnose-audio-capture-acceptance --diagnose-output "$ACCEPTANCE_JSON"; then
  pass "acceptance recording command completed"
else
  printf 'Acceptance output: %s\n' "$ACCEPTANCE_JSON" >&2
  fail "acceptance recording stayed silent"
fi

python3 - "$ACCEPTANCE_JSON" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

desktop_ok = data.get("rms_db", -120) > -80 or data.get("peak_db", -120) > -60
left_ok = data.get("audio_left_rms_db", -120) > -80 or data.get("audio_left_peak_db", -120) > -60

if not desktop_ok:
    raise SystemExit("FAIL desktop.caf is silent")
if not left_ok:
    raise SystemExit("FAIL audio.m4a left channel is silent")

print("PASS desktop.caf RMS/peak is non-silent")
print("PASS audio.m4a left channel RMS/peak is non-silent")
print("desktop_caf={}".format(data.get("desktop_url", "")))
print("audio_m4a={}".format(data.get("audio_url", "")))
print("desktop_rms_db={:.1f}".format(data.get("rms_db", -120)))
print("desktop_peak_db={:.1f}".format(data.get("peak_db", -120)))
print("audio_left_rms_db={:.1f}".format(data.get("audio_left_rms_db", -120)))
print("audio_left_peak_db={:.1f}".format(data.get("audio_left_peak_db", -120)))
PY
