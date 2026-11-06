#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${1:-}" == "--fullscreen-soak-report" ]]; then
  [[ $# == 3 ]] || { print -u2 'Usage: check-quality.sh --fullscreen-soak-report SIGNED_APP REPORT_DIRECTORY'; exit 2; }
  exec python3 scripts/require-fullscreen-soak-quality.py "$2" "$3"
fi
mkdir -p build
# Serialize shared build outputs and hardware access across chats/runners.
quality_lock="$PWD/build/.quality-lock"
while ! mkdir "$quality_lock" 2>/dev/null; do
  quality_owner_pid="$(cat "$quality_lock/pid" 2>/dev/null || true)"
  if [[ -n "$quality_owner_pid" ]] && ! kill -0 "$quality_owner_pid" 2>/dev/null; then
    rm -f "$quality_lock/pid"
    rmdir "$quality_lock" 2>/dev/null || true
  else
    sleep 1
  fi
done
print -r -- "$$" > "$quality_lock/pid"
export DESKCAPTURE_QUALITY_OWNER_PID="$$"
quality_report_dir="$(mktemp -d "${TMPDIR:-/tmp}/deskcapture-quality-report.XXXXXX")"
quality_run_id="quality-$$"
quality_home="$(mktemp -d "${TMPDIR:-/tmp}/deskcapture-quality-home.XXXXXX")"
trap 'python3 scripts/clear-diagnostic-preferences.py "$quality_home/unit-workspace" "$quality_report_dir"; rm -rf "$quality_home"; rm -f "$quality_lock/pid"; rmdir "$quality_lock" 2>/dev/null || true' EXIT
python3 scripts/check-preference-isolation.py "$quality_report_dir/preferences-before.plist"
# Python package-preflight cases join the final unified run; no real app fixtures.
python3 -m unittest discover -s scripts/tests > build/quality-python-tests.log 2>&1
# Standard preferences, default media libraries and clipboard fixtures are isolated.
# Use only explicitly supplied or owned pinned fixtures; tests verify their hashes.
if [[ -z "${DESKCAPTURE_SPEECH_TINY_FIXTURE:-}" && -f "$PWD/build/r37-ggml-tiny.bin" ]]; then
  export DESKCAPTURE_SPEECH_TINY_FIXTURE="$PWD/build/r37-ggml-tiny.bin"
fi
if [[ -z "${DESKCAPTURE_REPAIR_MODEL_FIXTURE:-}" && -f "$PWD/build/r15-model-fixture/LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin" ]]; then
  export DESKCAPTURE_REPAIR_MODEL_FIXTURE="$PWD/build/r15-model-fixture/LaMa.mlpackage"
fi
CFFIXED_USER_HOME="$quality_home" DESKCAPTURE_DIAGNOSTIC_DIR="$quality_home/unit-workspace" swift test > build/quality-tests.log 2>&1
if [[ "${1:-}" == "--existing-build" ]]; then
  /usr/bin/codesign --verify --deep --strict "$PWD/build/DeskCapture.app" > build/quality-build.log 2>&1
  /usr/bin/codesign --verify --deep --strict "$PWD/build/ScrollFixtureTarget.app" >> build/quality-build.log 2>&1
else
  ./scripts/build-app.sh release > build/quality-build.log 2>&1
  ./scripts/build-scroll-target.sh >> build/quality-build.log 2>&1
fi
python3 scripts/audit-app-compatibility.py "$PWD/build/DeskCapture.app" --output build/compatibility-audit.json > build/compatibility-audit.log
open -n "$PWD/build/DeskCapture.app" --env "CFFIXED_USER_HOME=$quality_home" --env "DESKCAPTURE_DIAGNOSTIC_DIR=$quality_report_dir" --env "DESKCAPTURE_DIAGNOSTIC_RUN_ID=$quality_run_id" --args --quality-diagnostic --diagnostic-run-id "$quality_run_id" -primaryShortcutEnabled NO -historyRetentionDays 0 -modeHotKeys ''
diagnostic_result=0
# Four real slow-scroll scenarios plus the two 55-second media holds need
# roughly 290 seconds. Keep a bounded watchdog with room for device teardown.
python3 scripts/monitor-quality.py "$quality_report_dir" "$quality_run_id" 360 || diagnostic_result=$?
if [[ -f "$quality_report_dir/deskcapture-quality-diagnostic.json" ]]; then
  cp "$quality_report_dir/deskcapture-quality-diagnostic.json" build/quality-diagnostic.json
fi
if [[ -f "$quality_report_dir/deskcapture-quality-performance.json" ]]; then
  cp "$quality_report_dir/deskcapture-quality-performance.json" build/quality-performance.json
fi
preference_result=0
python3 scripts/check-preference-isolation.py "$quality_report_dir/preferences-before.plist" --report build/quality-preference-isolation.json || preference_result=$?
if (( diagnostic_result == 0 && preference_result != 0 )); then diagnostic_result=$preference_result; fi
exit "$diagnostic_result"
