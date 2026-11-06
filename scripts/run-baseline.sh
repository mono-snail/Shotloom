#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/baselines
baseline_run="$PWD/build/baselines/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$baseline_run"
baseline_home="$(mktemp -d "${TMPDIR:-/tmp}/deskcapture-baseline-home.XXXXXX")"
trap 'rm -rf "$baseline_home"' EXIT
python3 - "$baseline_run" <<'SNAPSHOT'
import hashlib,json,pathlib,sys
source=pathlib.Path.cwd()
hashes={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for base in ['Sources','Tests','Resources'] for p in sorted((source/base).rglob('*')) if p.is_file() and p.suffix in ['.swift','.plist']}
(pathlib.Path(sys.argv[1])/'source-at-start.json').write_text(json.dumps(hashes,indent=2))
SNAPSHOT
# Every baseline links to current signed real capture/recording evidence.
baseline_quality_result=0
caffeinate -di ./scripts/check-quality.sh > "$baseline_run/quality-run.log" 2>&1 || baseline_quality_result=$?
print -r -- "$baseline_quality_result" > "$baseline_run/quality-exit-code.txt"
cp build/quality-tests.log build/quality-build.log build/quality-diagnostic.json build/quality-performance.json "$baseline_run/"
# Retain independent measurements even when real capture is unavailable.
open -n "$PWD/build/DeskCapture.app" --env "CFFIXED_USER_HOME=$baseline_home" --env "DESKCAPTURE_DIAGNOSTIC_DIR=$baseline_run" --args --workflow-benchmark
python3 - "$baseline_run" <<'PY'
import datetime, hashlib, json, pathlib, platform, plistlib, shutil, subprocess, sys, time
run=pathlib.Path(sys.argv[1]); report=run/'deskcapture-workflow-baseline.json'
started=time.monotonic()
while time.monotonic()-started<120:
    try: data=json.loads(report.read_text())
    except (OSError,ValueError): data={}
    if data.get('finished'): break
    time.sleep(.5)
else:
    (run/'baseline-failure.json').write_text(json.dumps({'success':False,'error':'benchmark exceeded 120 seconds'}))
    raise SystemExit('Benchmark timed out; no baseline completion claimed')
shutil.copy2(report,run/'workflow.json')
source=pathlib.Path.cwd()
hashes={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for base in ['Sources','Tests','Resources'] for p in sorted((source/base).rglob('*')) if p.is_file() and p.suffix in ['.swift','.plist']}
initial=json.loads((run/'source-at-start.json').read_text())
if hashes!=initial:
    changed=[key for key in sorted(set(hashes)|set(initial)) if hashes.get(key)!=initial.get(key)]
    (run/'baseline-failure.json').write_text(json.dumps({'success':False,'error':'Sources changed during measurement','changed':changed},indent=2))
    raise SystemExit('Sources changed during measurement; rerun against a stable final implementation')
installed=[]
for base in [pathlib.Path('/Applications'),pathlib.Path.home()/'Applications']:
    if not base.exists(): continue
    for app in base.glob('*.app'):
        if not any(key.casefold() in app.name.casefold() for key in ['CleanShot','Shottr','Snagit','Screen Studio','飞书','Lark']): continue
        try: info=plistlib.loads((app/'Contents/Info.plist').read_bytes())
        except (OSError,ValueError): info={}
        installed.append({'app':app.name,'bundleID':info.get('CFBundleIdentifier'),'version':info.get('CFBundleShortVersionString'),'measurementStatus':'not_run','reason':'Installed app metadata is not an authorized runnable benchmark or comparative result'})
metadata={'schema':1,'recordedAtUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'machineArchitecture':platform.machine(),'sourceSHA256':hashes,'binarySHA256':hashlib.sha256((source/'build/DeskCapture.app/Contents/MacOS/DeskCapture').read_bytes()).hexdigest(),'competitorInventory':installed,'missingComparators':[name for name in ['CleanShot','Shottr','Snagit','Screen Studio'] if not any(name.casefold() in a['app'].casefold() for a in installed)],'qualityReport':'quality-diagnostic.json','workflowReport':'workflow.json','scope':'Developer API stages and fixed synthetic corpus; not complete UI workflows or a competitor ranking'}
(run/'manifest.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2))
print('Baseline:',run)
print('Measured cases:',len(data.get('cases',[])),'success:',data.get('success'))
quality=json.loads((run/'quality-diagnostic.json').read_text())
if not data.get('success') or not quality.get('success') or (run/'quality-exit-code.txt').read_text().strip() != '0': raise SystemExit(1)
PY
