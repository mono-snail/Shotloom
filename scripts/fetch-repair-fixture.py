#!/usr/bin/env python3
"""Fetch a pinned public Core ML research fixture into build, never a user model library."""
import hashlib, json, os, pathlib, subprocess, tempfile, time
ROOT = pathlib.Path(__file__).resolve().parents[1]
REVISION = '5ed76e3799ab4cad31381750d29880c267477e18'
BASE = 'https://huggingface.co/mlboydaisuke/LaMa-CoreML/resolve/' + REVISION + '/'
FILES = [
 ('LaMa.mlpackage/Manifest.json', 617, 'git-blob-sha1', '294b935fda2cb4bd8d177a12509df8cdde0d5ad9'),
 ('LaMa.mlpackage/Data/com.apple.CoreML/model.mlmodel', 1101809, 'sha256', '06a100ef99e0fd16326a3a8c4a687d13f7b26f544ea906a75338932d8554f953'),
 ('LaMa.mlpackage/Data/com.apple.CoreML/weights/weight.bin', 215544960, 'sha256', 'd0541f6044a94cd4982bfdac074fc1ccfe11d8f1f590c299d6b5071b501fc184')]
DESTINATION = ROOT / 'build/r15-model-fixture'

def matches(path, size, algorithm, expected):
    if not path.is_file() or path.is_symlink() or path.stat().st_size != size: return False
    if algorithm == 'git-blob-sha1':
        return hashlib.sha1(b'blob ' + str(size).encode() + b'\0' + path.read_bytes()).hexdigest() == expected
    with path.open('rb') as file: return hashlib.file_digest(file, 'sha256').hexdigest() == expected

def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    report = {'repository': 'mlboydaisuke/LaMa-CoreML', 'revision': REVISION, 'scope': 'research fixture only; no redistribution or inference-quality claim', 'files': [], 'success': False}
    started = time.monotonic()
    try:
        for name, size, algorithm, expected in FILES:
            destination = DESTINATION / name; destination.parent.mkdir(parents=True, exist_ok=True)
            if not matches(destination, size, algorithm, expected):
                fd, temporary = tempfile.mkstemp(prefix='.download-', dir=destination.parent); os.close(fd)
                stage = pathlib.Path(temporary)
                try:
                    print(json.dumps({'downloading':name,'bytes':size}), flush=True)
                    subprocess.run(['curl','--noproxy','*','--fail','--silent','--show-error','--location','--connect-timeout','8','--max-time','300','--max-filesize',str(size),BASE+name,'--output',str(stage)], check=True)
                    if not matches(stage,size,algorithm,expected): raise ValueError('Pinned file size/hash mismatch: '+name)
                    os.replace(stage,destination)
                finally:
                    stage.unlink(missing_ok=True)
            with destination.open('rb') as file: digest = hashlib.file_digest(file,'sha256').hexdigest()
            report['files'].append({'path':name,'bytes':size,'sha256':digest,'verification':algorithm})
            print(json.dumps({'verified':name,'bytes':size}), flush=True)
        report['success'] = True
    except Exception as error:
        report['error'] = str(error)
        raise
    finally:
        report['seconds'] = time.monotonic()-started
        (DESTINATION/'acquisition.json').write_text(json.dumps(report,indent=2)+'\n')

if __name__ == '__main__': main()
