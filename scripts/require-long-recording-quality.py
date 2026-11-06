#!/usr/bin/env python3
"""Distinguish resource-run success from continuous requested camera coverage."""
import argparse
import hashlib
import json
import math
import pathlib
import plistlib
import subprocess


def verify(app, report):
    app, report = pathlib.Path(app), pathlib.Path(report)
    data = json.loads(report.read_text())
    if data.get('finished') is not True or data.get('success') is not True or data.get('scope') != 'long-recording-resources-only':
        raise ValueError('A finished successful long recording resource report is required.')
    rows = data.get('cases', [])
    if len(rows) != 1 or rows[0].get('case') != 'long-recording-resources' or rows[0].get('success') is not True:
        raise ValueError('The long recording case is missing or failed.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    with (app / 'Contents/MacOS/DeskCapture').open('rb') as file:
        digest = hashlib.file_digest(file, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(file.read()).hexdigest()
    if data.get('executableSHA256') != digest or data.get('version') != info.get('CFBundleShortVersionString') or data.get('build') != info.get('CFBundleVersion'):
        raise ValueError('The long recording report belongs to a different application.')
    row = rows[0]
    def seconds(key):
        value = row.get(key)
        if isinstance(value, bool) or not isinstance(value, (float, int)) or not math.isfinite(value) or value <= 0:
            raise ValueError('Missing or invalid duration: ' + key)
        return value
    requested, duration = seconds('requestedSeconds'), seconds('durationSeconds')
    if not 1800 <= requested <= 3600 or duration < requested - 1:
        raise ValueError('The screen movie did not cover the requested long recording.')
    if not isinstance(row.get('cameraEnabled'), bool):
        raise ValueError('Requested camera configuration is missing.')
    if row['cameraEnabled']:
        camera_duration = seconds('cameraDurationSeconds')
        if camera_duration < duration - 1:
            raise ValueError(f'Camera coverage is incomplete: {camera_duration:.3f}s for a {duration:.3f}s screen movie.')
        if '摄像头' in row.get('warning', ''):
            raise ValueError('The long recording reported a camera interruption; continuous camera coverage is not accepted.')
    return digest


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('report', type=pathlib.Path)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    args = parser.parse_args()
    if args.output.resolve() == args.report.resolve():
        parser.error('The acceptance result must not replace the raw report.')
    result = {'success': False, 'scope': 'long-recording-duration-and-camera-continuity',
              'limits': 'Duration/diagnostic-warning checks only; full media decode, visual correctness and AV synchronization are separate.'}
    try:
        result['candidateSHA256'] = verify(args.app, args.report)
        subprocess.run(['codesign', '--verify', '--deep', '--strict', '--all-architectures', str(args.app)], check=True, capture_output=True)
        result['success'] = True
    except Exception as error:
        result['error'] = str(error)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + '\n')
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0 if result['success'] else 1)
