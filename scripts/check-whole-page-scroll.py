#!/usr/bin/env python3
"""Complete owned-document production sessions; never uses user media/preferences."""
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile
import uuid

root = pathlib.Path(__file__).resolve().parent.parent
app = root / 'build/DeskCapture.app'
binary = app / 'Contents/MacOS/DeskCapture'
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(root / 'build/ScrollFixtureTarget.app')], check=True)
before = hashlib.sha256(binary.read_bytes()).hexdigest()
run_id = 'whole-page-' + uuid.uuid4().hex
report = root / 'build/whole-page-diagnostics' / run_id
report.mkdir(parents=True)
(report / 'case-at-start.json').write_text(json.dumps({
    'binarySHA256': before, 'directions': ['forward', 'reverse'],
    'completeDocumentRequired': True, 'fixedBars': True, 'nestedContainer': True,
    'strictSourceRGBAErrorAllowed': 0, 'originalDisplayRGBErrorAllowed': 2,
    'forwardDelayMS': 900, 'forwardTransitionMS': 1200, 'reverseDelayMS': 1800,
}, indent=2))
print(report, flush=True)
with tempfile.TemporaryDirectory(prefix='deskcapture-whole-page-home-') as home:
    subprocess.run(['open', '-n', str(app), '--env', 'CFFIXED_USER_HOME=' + home,
                    '--env', 'DESKCAPTURE_DIAGNOSTIC_DIR=' + str(report),
                    '--env', 'DESKCAPTURE_DIAGNOSTIC_RUN_ID=' + run_id,
                    '--args', '--quality-diagnostic', '--diagnostic-run-id', run_id,
                    '--whole-page-scroll-diagnostic', '-primaryShortcutEnabled', 'NO', '-modeHotKeys', ''], check=True)
    result = subprocess.run(['python3', str(root / 'scripts/monitor-quality.py'), str(report), run_id, '340'])
    path = report / 'deskcapture-quality-diagnostic.json'
    if path.exists():
        data = json.loads(path.read_text())
        artifacts = pathlib.Path(data['artifacts'])
        if artifacts.name.startswith('DeskCapture-quality-') and artifacts.is_dir():
            shutil.copytree(artifacts, report / 'artifacts')
    outcome = result.returncode
    if outcome == 0:
        outcome = subprocess.run(['swift', str(root / 'scripts/normalize-whole-page-sources.swift'), str(report)]).returncode
        if outcome == 0:
            runtime = pathlib.Path.home() / '.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3'
            outcome = subprocess.run([str(runtime), str(root / 'scripts/verify-whole-page-scroll.py'), str(report)]).returncode
    after = hashlib.sha256(binary.read_bytes()).hexdigest()
    (report / 'binary-at-end.json').write_text(json.dumps({'sha256': after, 'unchanged': before == after}, indent=2))
    raise SystemExit(outcome if before == after else 3)
