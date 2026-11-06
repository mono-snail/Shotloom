#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${2:-}" == "--existing-build" ]]; then
 /usr/bin/codesign --verify --deep --strict "$PWD/build/DeskCapture.app"
 /usr/bin/codesign --verify --deep --strict "$PWD/build/ScrollFixtureTarget.app"
else
 ./scripts/build-app.sh release > build/upward-build.log 2>&1
 ./scripts/build-scroll-target.sh >> build/upward-build.log 2>&1
fi
python3 - "${1:-}" <<'PY'
import os,pathlib,subprocess,tempfile,uuid,sys
root=pathlib.Path.cwd(); run_id='upward-'+uuid.uuid4().hex
report=root/'build'/'upward-diagnostics'/run_id; report.mkdir(parents=True)
with tempfile.TemporaryDirectory(prefix='deskcapture-upward-home-') as home:
 subprocess.run(['open','-n',str(root/'build/DeskCapture.app'),'--env','CFFIXED_USER_HOME='+home,'--env','DESKCAPTURE_DIAGNOSTIC_DIR='+str(report),'--env','DESKCAPTURE_DIAGNOSTIC_RUN_ID='+run_id,'--args','--quality-diagnostic','--diagnostic-run-id',run_id,'--upward-scroll-diagnostic','-primaryShortcutEnabled','NO','-modeHotKeys','']+(['--inspect-scroll-container-ui'] if sys.argv[1]=='--inspect-ui' else ['--inspect-fixed-bars-ui'] if sys.argv[1]=='--inspect-fixed-ui' else ['--inspect-dynamic-regions-ui'] if sys.argv[1]=='--inspect-dynamic-ui' else []),check=True)
 result=subprocess.run(['python3','scripts/monitor-quality.py',str(report),run_id])
 print('Debug-only report:',report)
 raise SystemExit(result.returncode)
PY
