#!/usr/bin/env python3
"""Read-only guard for the installed app's persistent preference domain."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('snapshot', type=pathlib.Path)
parser.add_argument('--report', type=pathlib.Path)
args = parser.parse_args()
result = subprocess.run(['/usr/bin/defaults', 'export', 'app.monoware.shotloom', '-'],
                        capture_output=True, check=True)
current = plistlib.loads(result.stdout)
canonical = plistlib.dumps(current, fmt=plistlib.FMT_BINARY, sort_keys=True)
if args.report is None:
    args.snapshot.write_bytes(canonical)
    args.snapshot.chmod(0o600)
else:
    original = plistlib.loads(args.snapshot.read_bytes())
    before = plistlib.dumps(original, fmt=plistlib.FMT_BINARY, sort_keys=True)
    changed = sorted(key for key in set(original) | set(current)
                     if original.get(key) != current.get(key))
    report = {'success': before == canonical, 'changedKeys': changed,
              'beforeSHA256': hashlib.sha256(before).hexdigest(),
              'afterSHA256': hashlib.sha256(canonical).hexdigest(),
              'scope': 'Installed app.monoware.shotloom persistent preferences; excludes global OS preferences.'}
    args.report.write_text(json.dumps(report, indent=2))
    print('Installed app preferences preserved:', report['success'])
    raise SystemExit(0 if report['success'] else 1)
