import json, subprocess, time, pathlib, sys, re
directory=pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else pathlib.Path('/tmp')
run_id=sys.argv[2] if len(sys.argv)>2 else None
report=directory/'deskcapture-quality-diagnostic.json'
pattern='DeskCapture.app/Contents/MacOS/DeskCapture --quality-diagnostic' + (' --diagnostic-run-id '+re.escape(run_id)+'( |$)' if run_id else '')
timeout_seconds=int(sys.argv[3]) if len(sys.argv)>3 else 300
started=time.monotonic(); peak_rss=0; samples=[]; last_count=0
while time.monotonic()-started<timeout_seconds:
    procs=subprocess.run(['pgrep','-f',pattern],capture_output=True,text=True).stdout.split()
    if procs:
        stats=subprocess.run(['ps','-p',procs[0],'-o','rss=,%cpu='],capture_output=True,text=True).stdout.split()
        if len(stats)==2:
            peak_rss=max(peak_rss,int(stats[0])); samples.append({'seconds':round(time.monotonic()-started,2),'rssKB':int(stats[0]),'cpuPercent':float(stats[1])})
    if report.exists():
        try: data=json.loads(report.read_text())
        except Exception: data={}
        if run_id and data.get('runID') != run_id:
            time.sleep(1); continue
        rows=data.get('cases',[])
        if len(rows)!=last_count:
            for row in rows[last_count:]: print(json.dumps(row,ensure_ascii=False),flush=True)
            last_count=len(rows)
        if data.get('finished'):
            (directory/'deskcapture-quality-performance.json').write_text(json.dumps({'peakRSSMiB':peak_rss/1024,'samples':samples},indent=2))
            print('finished, peak RSS MiB:',peak_rss/1024,flush=True)
            raise SystemExit(0 if data.get('success') else 1)
    time.sleep(1)
print('quality diagnostic exceeded',timeout_seconds,'seconds',flush=True)
if procs:
    subprocess.run(['sample',procs[0],'2','-file',str(directory/'deskcapture-quality-hang.txt')],capture_output=True)
    # Only the explicit diagnostic process is terminated; recordings are temporary.
    subprocess.run(['kill','-TERM',procs[0]],capture_output=True)
(directory/'deskcapture-quality-performance.json').write_text(json.dumps({'timeout':True,'peakRSSMiB':peak_rss/1024,'samples':samples},indent=2))
raise SystemExit(2)
