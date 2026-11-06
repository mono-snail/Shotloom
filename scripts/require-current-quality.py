#!/usr/bin/env python3
"""Reject historical/debug-only reports when packaging a current signed candidate."""
import hashlib, json, pathlib, plistlib, subprocess, sys

REQUIRED_CASES = {
    'scroll-full-region-visibility', 'daily-history-copy-clipboard-edit',
    'scroll-dynamic-manual-recovery', 'scroll-dynamic-automatic-recovery',
    'workflow-region-input-confirm-cancel-isolation', 'native-screen-region-window-capture', 'large-image-history-project-ocr-exports',
    'image-cleanup-strip-trim-foreground-cancel', 'native-long-image-start-save-cancel',
    'large-long-image-worker-responsive', 'native-upward-scroll-generated-target',
    'native-scroll-reverse-1800ms', 'native-scroll-forward-900ms', 'native-scroll-forward-1800ms',
    'native-scroll-top-boundary', 'streamed-long-beyond-old-limits',
    'camera-repeated-stop-preview-teardown', 'device-window-close-saves-active-recording',
    'screen-camera-30fps-pause-resume-export-cancel'
}

def verify(app, report):
    app, report = pathlib.Path(app), pathlib.Path(report)
    data = json.loads(report.read_text())
    if data.get('finished') is not True or data.get('success') is not True or data.get('scope') != 'full' or not data.get('cases'):
        raise ValueError('Current full signed-app quality evidence is required.')
    names = [row.get('case') for row in data['cases']]
    if len(set(names)) != len(names) or not REQUIRED_CASES.issubset(set(names)):
        raise ValueError('Full signed-app quality case set is missing or duplicated.')
    if any(row.get('success') is not True for row in data['cases']):
        raise ValueError('A quality case did not succeed.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    with (app / 'Contents/MacOS/DeskCapture').open('rb') as file:
        digest = hashlib.file_digest(file, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(file.read()).hexdigest()
    if data.get('executableSHA256') != digest or data.get('version') != info.get('CFBundleShortVersionString') or data.get('build') != info.get('CFBundleVersion'):
        raise ValueError('Quality report belongs to a different executable/version/build.')
    return digest

if __name__ == '__main__':
    app = pathlib.Path(sys.argv[1]); report = pathlib.Path(sys.argv[2])
    digest = verify(app, report)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)], check=True)
    print(digest)
