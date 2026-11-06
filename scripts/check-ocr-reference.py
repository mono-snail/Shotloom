#!/usr/bin/env python3
"""Run the signed OCR reference entry with generated images and isolated preferences."""
import hashlib,json,os,pathlib,subprocess,tempfile,time,uuid
root=pathlib.Path(__file__).resolve().parent.parent
app=root/'build/DeskCapture.app'
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
run=pathlib.Path(tempfile.mkdtemp(prefix='ocr-reference-',dir=root/'build/baselines'))
def hashes():
    return {str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'Sources').rglob('*.swift')}
initial=hashes(); binary=hashlib.sha256((app/'Contents/MacOS/DeskCapture').read_bytes()).hexdigest()
run_id=str(uuid.uuid4()); samples=[]; last_sample=0
with tempfile.TemporaryDirectory(prefix='deskcapture-ocr-home-') as home:
    subprocess.run(['open','-n',str(app),'--env','CFFIXED_USER_HOME='+home,'--env','DESKCAPTURE_DIAGNOSTIC_DIR='+str(run),'--args','--ocr-reference-benchmark','--ocr-reference-run-id',run_id],check=True)
    began=time.monotonic();report=run/'ocr-reference.json'
    while time.monotonic()-began<180:
        elapsed=time.monotonic()-began
        if elapsed-last_sample>=1:
            last_sample=elapsed
            process_rows=subprocess.run(['ps','-axo','pid=,rss=,args='],capture_output=True,text=True,check=True).stdout.splitlines()
            for process_row in process_rows:
                parts=process_row.strip().split(None,2)
                expected=str(app/'Contents/MacOS/DeskCapture')+' --ocr-reference-benchmark --ocr-reference-run-id '+run_id
                if len(parts)==3 and parts[2].strip()==expected:
                    samples.append({'seconds':elapsed,'pid':int(parts[0]),'rssMiB':int(parts[1])/1024})
        try: data=json.loads(report.read_text())
        except (OSError,ValueError): data={}
        if data.get('finished'): break
        time.sleep(.25)
    else: raise SystemExit('OCR reference timed out; no pass claimed: '+str(run))
    stable=initial==hashes() and binary==hashlib.sha256((app/'Contents/MacOS/DeskCapture').read_bytes()).hexdigest()
    (run/'manifest.json').write_text(json.dumps({'binarySHA256':binary,'sourceSHA256':initial,'sourceAndBinaryStable':stable,'generatedInputSHA256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in run.glob('*.png')}},indent=2))
    (run/'ocr-performance.json').write_text(json.dumps({'runID':run_id,'samplingIntervalSeconds':1,'peakRSSMiB':max((s['rssMiB'] for s in samples),default=None),'samples':samples,'scope':'Exact owned OCR process; one-second sampling can miss short peaks'},indent=2))
    print(run)
    for row in data['cases']: print(row['id'],'CER',row.get('strictCER'),'table',row.get('tableStructureAndValuesExact'),'QR',row.get('payloadExact'),row.get('error',''))
    if not stable or not data.get('success'): raise SystemExit(1)
