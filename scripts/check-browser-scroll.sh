#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
if [[ "${3:-}" == "--existing-build" ]]; then
 /usr/bin/codesign --verify --deep --strict "$PWD/build/DeskCapture.app"
else
 ./scripts/build-app.sh release > build/browser-build.log 2>&1
fi
python3 - "${1:?fixture directory required}" "${2:?case ID required}" <<'PY'
import json,pathlib,subprocess,tempfile,uuid,sys,hashlib,urllib.request,urllib.parse,plistlib
root=pathlib.Path.cwd(); fixture=pathlib.Path(sys.argv[1]).resolve(); case=sys.argv[2]
address=json.loads((fixture/'server.json').read_text())['url']
parsed=urllib.parse.urlsplit(address)
if parsed.scheme!='http' or parsed.hostname!='127.0.0.1':raise SystemExit('Only the loopback fixture is permitted')
manifest=root/'docs/R10-预定义案例.json'
expected_hash=(fixture/'cases-at-start.sha256').read_text().strip()
if hashlib.sha256(manifest.read_bytes()).hexdigest()!=expected_hash:raise SystemExit('Case manifest changed after freeze')
expected=next(c for c in json.loads(manifest.read_text())['cases'] if c['id']==case)
observed=json.loads(urllib.request.urlopen(address+'/state/'+case).read())
for key,wanted in [('axis',expected['axis']),('reverse',expected['direction']=='reverse'),('fixed',expected['fixed']),('delay',expected['delay']),('loadingDelay',expected.get('loadingDelay',0))]:
 if observed.get(key,0 if key=='loadingDelay' else None)!=wanted:raise SystemExit('Fixture does not match predefined case: '+key)
if not observed.get('ready') or observed.get('wheels')!=0 or observed.get('pending')!=0:raise SystemExit('Reset the owned fixture before each attempt')
run_id='browser-'+uuid.uuid4().hex
report=root/'build'/'browser-diagnostics'/run_id; report.mkdir(parents=True)
binary=root/'build/DeskCapture.app/Contents/MacOS/DeskCapture'
binary_hash=hashlib.sha256(binary.read_bytes()).hexdigest()
info=plistlib.loads((root/'build/DeskCapture.app/Contents/Info.plist').read_bytes())
(report/'case-at-start.json').write_text(json.dumps({'case':expected,'caseManifestSHA256':expected_hash,'initialState':observed,'binarySHA256':binary_hash,'version':info['CFBundleShortVersionString'],'build':info['CFBundleVersion']},ensure_ascii=False,indent=2))
print('Browser report:',report,flush=True)
with tempfile.TemporaryDirectory(prefix='deskcapture-browser-home-') as home:
 subprocess.run(['open','-g','-n',str(root/'build/DeskCapture.app'),'--env','CFFIXED_USER_HOME='+home,'--env','DESKCAPTURE_DIAGNOSTIC_DIR='+str(report),'--env','DESKCAPTURE_DIAGNOSTIC_RUN_ID='+run_id,'--env','DESKCAPTURE_BROWSER_FIXTURE_URL='+address,'--env','DESKCAPTURE_BROWSER_CASE='+case,'--args','--quality-diagnostic','--diagnostic-run-id',run_id,'--browser-scroll-diagnostic','-primaryShortcutEnabled','NO','-modeHotKeys',''],check=True)
 outcome=subprocess.run(['python3','scripts/monitor-quality.py',str(report),run_id]).returncode
 if outcome==0:
  data=json.loads((report/'deskcapture-quality-diagnostic.json').read_text())
  wanted={'Chrome':'com.google.Chrome','Safari':'com.apple.Safari'}[expected['app']]
  matches=bool(data.get('cases') and data['cases'][0].get('browser')==wanted)
  (report/'app-classification.json').write_text(json.dumps({'expected':wanted,'matches':matches},indent=2))
  if not matches:outcome=1
  if outcome==0:
   outcome=subprocess.run(['swift','scripts/verify-browser-scroll-output.swift',str(report/'deskcapture-quality-diagnostic.json'),str(fixture)]).returncode
 stable=hashlib.sha256(binary.read_bytes()).hexdigest()==binary_hash
 (report/'binary-at-end.json').write_text(json.dumps({'unchanged':stable,'sha256':hashlib.sha256(binary.read_bytes()).hexdigest()},indent=2))
 raise SystemExit(outcome if stable else 3)
PY
