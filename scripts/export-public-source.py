#!/usr/bin/env python3
"""Export a fresh source snapshot. Never exports git history, accounts or build output."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
destination = args.destination.resolve()
if destination.exists():
    raise SystemExit('Destination must not exist; snapshots are never overwritten.')
if destination == ROOT or ROOT in destination.parents and 'build' not in destination.relative_to(ROOT).parts:
    raise SystemExit('Use a separate destination or a build subdirectory.')
destination.mkdir(parents=True)
for name in ['Sources', 'Resources', 'Tests', 'scripts', 'Shotloom.xcodeproj']:
    shutil.copytree(ROOT / name, destination / name,
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc', 'xcuserdata', '*.xcuserstate'))
for name in ['Package.swift', 'LICENSE']:
    shutil.copy2(ROOT / name, destination / name)
for name in ['README.md', 'THIRD_PARTY.md', 'VALIDATION.md']:
    shutil.copy2(ROOT / 'docs/public-source' / name, destination / name)
# The export helper must remain usable with this public layout too.
public_docs = destination / 'docs/public-source'
public_docs.mkdir(parents=True)
for name in ['README.md', 'THIRD_PARTY.md', 'VALIDATION.md']:
    shutil.copy2(ROOT / 'docs/public-source' / name, public_docs / name)
notices = destination / 'ThirdPartyNotices'
notices.mkdir()
for folder, pattern in [('build/speech-licenses', '*'), ('build/voice-runtime', '*COPYING.txt'),
                        ('build/voice-runtime', '*NOTICES.txt')]:
    for path in sorted((ROOT / folder).glob(pattern)):
        if path.is_file(): shutil.copy2(path, notices / path.name)
shutil.copy2(ROOT / '.build/artifacts/deskcapture/Sparkle/LICENSE', notices / 'Sparkle.txt')
(destination / '.gitignore').write_text('.build/\nbuild/\n.DS_Store\n.swiftpm/\n__pycache__/\n*.py[cod]\nxcuserdata/\n*.xcuserstate\n')
manifest = {}
for path in sorted(destination.rglob('*')):
    if path.is_symlink(): raise SystemExit('Symlink requires explicit review: ' + str(path))
    if path.is_file():
        if path.stat().st_size > 12_000_000: raise SystemExit('Unexpected large file: ' + str(path))
        manifest[str(path.relative_to(destination))] = hashlib.sha256(path.read_bytes()).hexdigest()
(destination / 'SOURCE_MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
print('Exported', len(manifest), 'files to', destination)
