#!/usr/bin/env python3
"""Accept a real-UI fullscreen soak's signed candidate and measured evidence.

This is deliberately a separate scope from full release quality acceptance.
The UI run, resource sampling and complete media decode must finish first.
"""
import hashlib
import json
import math
import pathlib
import plistlib
import subprocess
import sys


def verify(app, root):
    config = json.loads((root / 'configuration.json').read_text())
    media = json.loads((root / 'media-decode.json').read_text())
    cadence = json.loads((root / 'cadence.json').read_text())
    completion = json.loads((root / 'completion.json').read_text())
    samples = [json.loads(line) for line in (root / 'resources.jsonl').read_text().splitlines()]
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    binary = app / 'Contents/MacOS' / info['CFBundleExecutable']
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    assert digest == config['executableSHA256'], 'Candidate identity changed'
    assert info['CFBundleVersion'] == config['build'], 'Candidate build changed'
    assert config['selectedPixels'] == completion['displayPixels'], 'Selection did not cover display'
    assert completion['realDisplayCapture'] is True and completion['saved'] is True
    assert media['success'] is True and cadence['success'] is True, 'Media verification failed'
    assert media['inputSHA256'] == completion['movieSHA256'], 'Verified movie identity differs'
    assert cadence['durationSeconds'] >= 1800 and media['durationSeconds'] >= 1800, 'Less than 30 minutes'
    assert abs(cadence['durationSeconds'] - media['durationSeconds']) < 0.1
    video = [track for track in media['tracks'] if track['kind'] == 'video']
    assert len(video) == 1 and video[0]['decodedEnd'] >= media['durationSeconds'] - 1, 'Incomplete video decode'
    assert video[0]['nonmonotonicBuffers'] == 0, 'Video timestamps went backwards'
    assert cadence['width'] >= 3840 and cadence['height'] >= 2160, 'Not a large fullscreen output'
    assert cadence['averageFPS'] >= config['configuredFPS'] * 0.95, 'Average cadence below 95% of configured FPS'
    assert len(samples) >= 300 and samples[-1]['seconds'] - samples[0]['seconds'] >= 1790, 'Resource observation incomplete'
    assert all(math.isfinite(row['rssKiB']) and row['rssKiB'] > 0 for row in samples)
    peak = max(row['rssKiB'] for row in samples) / 1024
    assert peak < 1024, 'Recording RSS exceeded the 1 GiB diagnostic budget'
    return {'candidateSHA256': digest, 'durationSeconds': cadence['durationSeconds'],
            'averageFPS': cadence['averageFPS'], 'peakRecordingRSSMiB': peak,
            'observedSeconds': samples[-1]['seconds'] - samples[0]['seconds']}


if __name__ == '__main__':
    app, root = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
    result = {'finished': True, 'success': False, 'scope': 'real-ui-fullscreen-soak-only',
              'limits': 'Installed signed candidate only; no camera/microphone, disk exhaustion, AV synchronization, whole-system/GPU memory or full release-suite claim. Recording RSS budget: 1 GiB; average cadence: at least 95% of configured FPS.'}
    try:
        result.update(verify(app, root))
        result['success'] = True
    except Exception as error:
        result['error'] = str(error)
    (root / 'fullscreen-soak-acceptance.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(0 if result['success'] else 1)
