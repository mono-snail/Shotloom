#!/bin/zsh
# Final unified acceptance only: requires an already built current signed app.
set -euo pipefail
cd "${0:A:h:h}"
long_seconds="${DESKCAPTURE_LONG_RECORDING_SECONDS:-1800}"
if [[ "$long_seconds" != <-> ]] || (( long_seconds < 1800 || long_seconds > 3600 )); then
  print -u2 -- 'DESKCAPTURE_LONG_RECORDING_SECONDS must be 1800–3600.'
  exit 2
fi
/usr/bin/codesign --verify --deep --strict "$PWD/build/DeskCapture.app"
long_lock="$PWD/build/.quality-lock"
if ! mkdir "$long_lock" 2>/dev/null; then
  print -u2 -- 'Another quality run owns build/.quality-lock; no concurrent hardware diagnostic was started.'
  exit 2
fi
print -r -- "$$" > "$long_lock/pid"
long_home="$(mktemp -d "${TMPDIR:-/tmp}/deskcapture-long-home.XXXXXX")"
long_report="$(mktemp -d "${TMPDIR:-/tmp}/deskcapture-long-report.XXXXXX")"
long_run="long-recording-$$"
camera_device_arguments=()
if [[ -n "${DESKCAPTURE_LONG_CAMERA_DEVICE_ID:-}" ]]; then
  camera_device_arguments=(-recordCameraDevice "$DESKCAPTURE_LONG_CAMERA_DEVICE_ID")
fi
trap 'rm -rf "$long_home"; rm -f "$long_lock/pid"; rmdir "$long_lock" 2>/dev/null || true' EXIT
open -n "$PWD/build/DeskCapture.app" --env "CFFIXED_USER_HOME=$long_home" --env "DESKCAPTURE_DIAGNOSTIC_DIR=$long_report" --env "DESKCAPTURE_DIAGNOSTIC_RUN_ID=$long_run" --env "DESKCAPTURE_LONG_RECORDING_SECONDS=$long_seconds" --env "DESKCAPTURE_LONG_CAMERA=${DESKCAPTURE_LONG_CAMERA:-1}" --env "DESKCAPTURE_LONG_MICROPHONE=${DESKCAPTURE_LONG_MICROPHONE:-0}" --args --quality-diagnostic --diagnostic-run-id "$long_run" --long-recording-diagnostic -primaryShortcutEnabled NO -historyRetentionDays 0 -modeHotKeys '' "${camera_device_arguments[@]}"
long_result=0
python3 scripts/monitor-quality.py "$long_report" "$long_run" "$((long_seconds + 1800))" || long_result=$?
if [[ -f "$long_report/deskcapture-quality-diagnostic.json" ]]; then
  cp "$long_report/deskcapture-quality-diagnostic.json" build/long-recording-diagnostic.json
fi
if [[ -f "$long_report/deskcapture-quality-performance.json" ]]; then
  cp "$long_report/deskcapture-quality-performance.json" build/long-recording-performance.json
fi
if (( long_result == 0 )); then
  python3 scripts/require-long-recording-quality.py "$PWD/build/DeskCapture.app" "$long_report/deskcapture-quality-diagnostic.json" --output build/long-recording-acceptance.json || long_result=$?
fi
print -r -- "Long recording report: $long_report"
exit "$long_result"
