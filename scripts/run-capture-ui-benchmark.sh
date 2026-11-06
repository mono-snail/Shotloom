#!/bin/zsh
set -euo pipefail
setopt extendedglob
cd "${0:A:h:h}"
benchmark_label="${1:-capture-ui}"
benchmark_app="${2:-$PWD/build/DeskCapture.app}"
if [[ "$benchmark_label" != [a-zA-Z0-9_-]## ]]; then
  print -u2 "Benchmark label must contain only letters, numbers, hyphens or underscores."
  exit 1
fi
benchmark_run="$PWD/build/baselines/$benchmark_label-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$benchmark_run"
# Store a frozen source identity before compiling the measurement app.
python3 - "$benchmark_run" <<'PY'
import hashlib,json,pathlib,sys
root=pathlib.Path.cwd()
files={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for base in ['Sources','Tests','Resources'] for p in (root/base).rglob('*') if p.is_file() and p.suffix in ['.swift','.plist']}
(pathlib.Path(sys.argv[1])/'source-at-start.json').write_text(json.dumps(files,indent=2))
PY
if [[ $# -lt 2 ]]; then
  ./scripts/build-app.sh release > "$benchmark_run/build.log" 2>&1
else
  codesign --verify --deep --strict "$benchmark_app"
fi
python3 - "$benchmark_run" "$benchmark_app" <<'PY'
import hashlib,json,os,pathlib,subprocess,sys,tempfile,time
run=pathlib.Path(sys.argv[1]); root=pathlib.Path.cwd(); app=pathlib.Path(sys.argv[2])
with tempfile.TemporaryDirectory(prefix='deskcapture-ui-benchmark-home-') as isolated_home:
    subprocess.run(['open','-n',str(app),'--env','CFFIXED_USER_HOME='+isolated_home,'--env','DESKCAPTURE_DIAGNOSTIC_DIR='+str(run),'--args','--capture-ui-benchmark'],check=True)
    report=run/'deskcapture-workflow-baseline.json'; began=time.monotonic()
    while time.monotonic()-began<120:
        try: data=json.loads(report.read_text())
        except (OSError,ValueError): data={}
        if data.get('finished'): break
        time.sleep(.25)
    else: raise SystemExit('UI benchmark timed out; not counted as passed')
    files={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for base in ['Sources','Tests','Resources'] for p in (root/base).rglob('*') if p.is_file() and p.suffix in ['.swift','.plist']}
    initial=json.loads((run/'source-at-start.json').read_text())
    manifest={'sourceStable':files==initial,'sourceSHA256':files,'binarySHA256':hashlib.sha256((app/'Contents/MacOS/DeskCapture').read_bytes()).hexdigest(),'appPath':str(app),'report':'deskcapture-workflow-baseline.json','scope':'Production coordinator, native display pass and synthetic copy to named pasteboard; excludes physical key dispatch and complete selection/annotation task'}
    (run/'manifest.json').write_text(json.dumps(manifest,indent=2))
    print('UI benchmark:',run)
    for row in data.get('cases',[]): print(row['case'],row.get('medianSeconds'),row.get('p95Seconds'),row.get('error',''))
    if not data.get('success') or not manifest['sourceStable']: raise SystemExit(1)
PY
