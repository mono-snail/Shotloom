#!/usr/bin/env python3
"""Final QA: signed bundled CLI + pinned Tiny + upstream JFK sample, network denied."""
import hashlib
import http.server
import json
import os
import pathlib
import re
import subprocess
import threading
import time
import uuid
import wave

root = pathlib.Path(__file__).resolve().parents[1]
app = root / 'build/DeskCapture.app'
engine = app / 'Contents/Resources/SpeechRuntime/whisper-cli'
model = root / 'build/r37-ggml-tiny.bin'
audio = root / 'build/whisper.cpp-d1be6fde11ac6e0407606b4e42fe72d34add8037/samples/jfk.wav'
report_root = root / ('build/baselines/r50-speech-' + uuid.uuid4().hex[:12])
report_root.mkdir(mode=0o700)
profile = '(version 1)(allow default)(deny network*)'
reference = 'And so my fellow Americans, ask not what your country can do for you, ask what you can do for your country.'


def sha(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def words(text):
    return re.findall(r"[a-z]+(?:'[a-z]+)?", text.lower())


def word_errors(expected, actual):
    previous = list(range(len(actual) + 1))
    for i, a in enumerate(expected, 1):
        row = [i]
        for j, b in enumerate(actual, 1):
            row.append(min(previous[j] + 1, row[-1] + 1, previous[j - 1] + (a != b)))
        previous = row
    return previous[-1]


class Canary(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'owned-network-canary')

    def log_message(self, *_):
        pass


report = {'scope': 'bundled CLI inference only; app conversion/editor and Chinese accuracy require separate checks',
          'reference': reference, 'acceptanceWERMaximum': 0.20, 'model': 'Tiny multilingual',
          'sample': str(audio.relative_to(root)), 'success': False}
try:
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True, capture_output=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(engine)], check=True, capture_output=True)
    report.update(executableSHA256=sha(app / 'Contents/MacOS/DeskCapture'), engineSHA256=sha(engine), modelSHA256=sha(model), audioSHA256=sha(audio))
    with wave.open(str(audio), 'rb') as file:
        report['audioSeconds'] = file.getnframes() / file.getframerate()
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Canary)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        request = ['/usr/bin/curl', '--noproxy', '*', '--max-time', '3', '-fsS', f'http://127.0.0.1:{server.server_port}/probe']
        ordinary = subprocess.run(request, capture_output=True, timeout=5)
        blocked = subprocess.run(['/usr/bin/sandbox-exec', '-p', profile] + request, capture_output=True, timeout=5)
        report['ordinaryCanarySucceeded'] = ordinary.returncode == 0 and ordinary.stdout == b'owned-network-canary'
        report['sandboxCanaryBlocked'] = blocked.returncode != 0
        report['sandboxCanaryExit'] = blocked.returncode
        report['sandboxCanaryDiagnostic'] = blocked.stderr.decode(errors='replace')[:500]
        if not report['ordinaryCanarySucceeded'] or not report['sandboxCanaryBlocked']:
            raise RuntimeError('Network isolation canary did not prove the intended policy.')
    finally:
        server.shutdown(); server.server_close(); thread.join(timeout=2)
    args = ['/usr/bin/sandbox-exec', '-p', profile, str(engine), '-m', str(model), '-f', str(audio), '-l', 'en', '-oj', '-of', str(report_root / 'transcript'), '-np', '-t', '4']
    environment = {'PATH': '/usr/bin:/bin', 'TMPDIR': str(report_root)}
    started = time.monotonic()
    peak_rss = 0
    with (report_root / 'engine.log').open('wb') as log:
        process = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, env=environment)
        try:
            while process.poll() is None:
                if time.monotonic() - started > 90:
                    raise TimeoutError('Owned inference exceeded 90 seconds.')
                sample = subprocess.run(['/bin/ps', '-p', str(process.pid), '-o', 'rss='], capture_output=True, text=True)
                if sample.stdout.strip().isdigit():
                    peak_rss = max(peak_rss, int(sample.stdout.strip()))
                time.sleep(0.1)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    process.kill(); process.wait()
    report.update(seconds=time.monotonic() - started, engineExit=process.returncode, sampledPeakRSSMiB=peak_rss / 1024, rssSamplingSeconds=0.1)
    if process.returncode:
        raise RuntimeError('Bundled whisper CLI failed; see engine.log.')
    output = json.loads((report_root / 'transcript.json').read_text())
    text = ' '.join(row['text'].strip() for row in output['transcription'])
    errors = word_errors(words(reference), words(text))
    report.update(actual=text, wordErrors=errors, referenceWords=len(words(reference)), WER=errors / len(words(reference)))
    report['success'] = report['WER'] <= report['acceptanceWERMaximum']
except Exception as error:
    report['error'] = str(error)
finally:
    (report_root / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
    print(json.dumps({'report': str(report_root / 'report.json'), 'success': report['success'], 'error': report.get('error'), 'WER': report.get('WER'), 'seconds': report.get('seconds')}, ensure_ascii=False))
raise SystemExit(0 if report['success'] else 1)
