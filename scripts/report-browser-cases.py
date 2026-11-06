#!/usr/bin/env python3
"""Retains all attempt reports. Unrun cases stay in the denominator."""
import hashlib,json,pathlib
root=pathlib.Path(__file__).resolve().parent.parent
manifest=root/'docs/R10-预定义案例.json'
digest=hashlib.sha256(manifest.read_bytes()).hexdigest()
current_binary=hashlib.sha256((root/'build/DeskCapture.app/Contents/MacOS/DeskCapture').read_bytes()).hexdigest()
cases=json.loads(manifest.read_text())['cases']
attempts={case['id']:[] for case in cases}
directories=list((root/'build/browser-diagnostics').glob('browser-*')) + list((root/'build/native-diagnostics').glob('native-scroll-*'))
directories.sort(key=lambda p: (p/'case-at-start.json').stat().st_mtime_ns if (p/'case-at-start.json').exists() else 0)
for directory in directories:
    start=directory/'case-at-start.json'; report=directory/'deskcapture-quality-diagnostic.json'
    if not start.exists() or not report.exists(): continue
    initial=json.loads(start.read_text());data=json.loads(report.read_text())
    if initial.get('caseManifestSHA256')!=digest: continue
    case=initial['case']['id'];rows=data.get('cases',[])
    if data.get('scope') not in ('browser-debug-only','native-debug-only') or case not in attempts or initial.get('probeOnly'): continue
    stable_path=directory/'binary-at-end.json'
    stable=json.loads(stable_path.read_text()).get('unchanged') if stable_path.exists() else None
    expected_app={'Chrome':'com.google.Chrome','Safari':'com.apple.Safari','TextEdit':'com.apple.TextEdit','Preview':'com.apple.Preview'}.get(initial['case']['app'])
    app_matches=bool(rows and rows[0].get('browser',rows[0].get('app'))==expected_app)
    pixels_path=directory/'verified-pixels.json'
    pixels=json.loads(pixels_path.read_text()) if pixels_path.exists() else None
    png_path=directory/'verified-png-rows.json'
    png=json.loads(png_path.read_text()) if png_path.exists() else None
    passed=data.get('finished') and data.get('success') and (stable is not False) and app_matches and (pixels is None or pixels.get('success')) and (png is None or png.get('success'))
    attempts[case].append({'report':str(directory.relative_to(root)),'runID':data.get('runID'),'finished':data.get('finished',False),'success':bool(passed),'binaryStabilityRecorded':stable,'binarySHA256':initial.get('binarySHA256'),'fullRGBA':pixels,'PNGReadback':png,'nativeCase':initial['case']['app'] in ('TextEdit','Preview'),'rows':rows})
passed=sum(bool(rows and rows[-1]['success']) for rows in attempts.values())
tested=sum(bool(rows) for rows in attempts.values())
current_passed=sum(bool(rows and rows[-1]['success'] and rows[-1]['binarySHA256']==current_binary and rows[-1]['binaryStabilityRecorded'] is True and rows[-1]['fullRGBA'] and rows[-1]['fullRGBA'].get('success') and (not rows[-1]['nativeCase'] or rows[-1]['PNGReadback'] and rows[-1]['PNGReadback'].get('success'))) for rows in attempts.values())
result={'caseManifestSHA256':digest,'totalPredefinedCases':len(cases),'casesAttempted':tested,'latestPassedCases':passed,'unrunCases':len(cases)-tested,'latestPassesOverAllPredefined':passed/len(cases),'currentBinarySHA256':current_binary,'currentBinaryVerifiedPasses':current_passed,'currentBinaryVerifiedPassesOverAllPredefined':current_passed/len(cases),'allAttemptsRetained':True,'attempts':attempts}
destination=root/'docs/R10-执行进度.json'
temporary=destination.with_suffix('.json.tmp')
temporary.write_text(json.dumps(result,ensure_ascii=False,indent=2))
temporary.replace(destination)
print(json.dumps({k:v for k,v in result.items() if k!='attempts'},ensure_ascii=False))
