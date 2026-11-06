#!/usr/bin/env python3
"""Run only explicitly generated native documents, with isolated app preferences."""
import pathlib,sys,subprocess,tempfile,uuid,json,hashlib,shutil,os
root=pathlib.Path(__file__).resolve().parent.parent
folder=pathlib.Path(sys.argv[1]).resolve(); case=sys.argv[2]
probe='--probe' in sys.argv[3:]
manifest=root/'docs/R10-预定义案例.json'
manifest_hash=hashlib.sha256(manifest.read_bytes()).hexdigest()
if manifest_hash!='7fed4bfee2ffd12a06bd1204e0b755a054730d59b2c70931b9d406160c38e244':raise SystemExit('Frozen manifest changed')
expected=next(c for c in json.loads(manifest.read_text())['cases'] if c['id']==case)
if expected['app'] not in ('TextEdit','Preview'):raise SystemExit('Native cases only')
input_hashes=json.loads((root/'docs/R10-原生输入哈希.json').read_text())
def validate_inputs():
 for name,wanted in input_hashes.items():
  target=(folder/name).resolve()
  if folder not in target.parents or not target.is_file() or hashlib.sha256(target.read_bytes()).hexdigest()!=wanted:raise SystemExit('Frozen native input changed: '+name)
validate_inputs()
entry=next(c for c in json.loads((folder/'native-inputs.json').read_text())['entries'] if c['id']==case)
for field in ('direction','variant','kind'):
 if entry[field]!=expected[field]:raise SystemExit('Native input classification mismatch: '+field)
binary=root/'build/DeskCapture.app/Contents/MacOS/DeskCapture'
subprocess.run(['codesign','--verify','--deep','--strict',str(root/'build/DeskCapture.app')],check=True)
run_id=('native-probe-' if probe else 'native-scroll-')+uuid.uuid4().hex
report=root/'build/native-diagnostics'/run_id;report.mkdir(parents=True)
sha=hashlib.sha256(binary.read_bytes()).hexdigest()
(report/'case-at-start.json').write_text(json.dumps({'case':expected,'caseManifestSHA256':manifest_hash,'binarySHA256':sha,'probeOnly':probe,'captureBoundaryInsetPoints':1,'inputHashesSHA256':hashlib.sha256((root/'docs/R10-原生输入哈希.json').read_bytes()).hexdigest()},ensure_ascii=False,indent=2))
print(report,flush=True)
with tempfile.TemporaryDirectory(prefix='deskcapture-native-home-') as home:
 subprocess.run(['open','-g','-n',str(root/'build/DeskCapture.app'),'--env','CFFIXED_USER_HOME='+home,'--env','DESKCAPTURE_DIAGNOSTIC_DIR='+str(report),'--env','DESKCAPTURE_DIAGNOSTIC_RUN_ID='+run_id,'--env','DESKCAPTURE_NATIVE_FIXTURE_DIR='+str(folder),'--env','DESKCAPTURE_NATIVE_CASE='+case,'--args','--quality-diagnostic','--diagnostic-run-id',run_id,'--native-document-probe' if probe else '--native-scroll-diagnostic','-primaryShortcutEnabled','NO','-modeHotKeys',''],check=True)
 outcome=subprocess.run(['python3',str(root/'scripts/monitor-quality.py'),str(report),run_id]).returncode
 diagnostic=report/'deskcapture-quality-diagnostic.json'
 if diagnostic.exists():
  data=json.loads(diagnostic.read_text()); artifacts=pathlib.Path(data['artifacts'])
  if artifacts.name.startswith('DeskCapture-quality-') and artifacts.exists():
   shutil.copytree(artifacts,report/'artifacts')
   pixels=artifacts/'verified-pixels.json'
   if pixels.exists():shutil.copy2(pixels,report/'verified-pixels.json')
 if outcome==0 and not probe:
  outcome=subprocess.run(['swift',str(root/'scripts/normalize-native-source-colors.swift'),str(report)]).returncode
  if outcome==0:
   runtime=pathlib.Path(os.environ.get('DESKCAPTURE_ARTIFACT_PYTHON',str(pathlib.Path.home()/'.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3')))
   outcome=subprocess.run([str(runtime) if runtime.is_file() else sys.executable,str(root/'scripts/verify-native-scroll-output.py'),str(report)]).returncode
 validate_inputs()
 end=hashlib.sha256(binary.read_bytes()).hexdigest()
 (report/'binary-at-end.json').write_text(json.dumps({'sha256':end,'unchanged':sha==end},indent=2))
 raise SystemExit(outcome if sha==end else 3)
