#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build
if [[ "${2:-}" == "--existing-build" ]]; then
 /usr/bin/codesign --verify --deep --strict "$PWD/build/DeskCapture.app"
else
 ./scripts/build-app.sh release > build/stream-build.log 2>&1
fi
python3 - "${1:-}" <<'PY'
import pathlib,subprocess,tempfile,uuid,sys
root=pathlib.Path.cwd(); run_id='stream-'+uuid.uuid4().hex
report=root/'build'/'stream-diagnostics'/run_id; report.mkdir(parents=True)
print('Stream report:',report,flush=True)
with tempfile.TemporaryDirectory(prefix='deskcapture-stream-home-') as home:
 subprocess.run(['open','-n',str(root/'build/DeskCapture.app'),'--env','CFFIXED_USER_HOME='+home,'--env','DESKCAPTURE_DIAGNOSTIC_DIR='+str(report),'--env','DESKCAPTURE_DIAGNOSTIC_RUN_ID='+run_id,'--args','--quality-diagnostic','--diagnostic-run-id',run_id,'--stream-export-diagnostic','-primaryShortcutEnabled','NO','-modeHotKeys','']+(['--inspect-stream-export-ui'] if sys.argv[1]=='--inspect-ui' else []),check=True)
 raise SystemExit(subprocess.run(['python3','scripts/monitor-quality.py',str(report),run_id]).returncode)
PY
