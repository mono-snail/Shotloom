#!/usr/bin/env python3
"""Developer install transaction; no downloads, automatic relaunch or app termination."""
import argparse, ctypes, fcntl, json, os, pathlib, plistlib, re, subprocess, tempfile, uuid

BUNDLE_ID = 'app.monoware.shotloom'

def signature(app):
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', str(app)], check=True, capture_output=True, timeout=120)
    result = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', str(app)], check=True, capture_output=True, text=True, timeout=120)
    team = re.search(r'^TeamIdentifier=([A-Z0-9]{10})$', result.stderr, re.M)
    digest = re.search(r'^CDHash=([0-9a-fA-F]{40,128})$', result.stderr, re.M)
    if not team or not digest:
        raise ValueError('A team signature is required; ad-hoc and missing identities are rejected.')
    requirement = 'identifier "' + BUNDLE_ID + '" and anchor apple generic and certificate leaf[subject.OU] = "' + team[1] + '"'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '--all-architectures', '-R', '=' + requirement, str(app)], check=True, capture_output=True, timeout=120)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != BUNDLE_ID:
        raise ValueError('Unrelated bundle identifier.')
    return dict(team=team[1], digest=digest[1].lower(), build=str(info.get('CFBundleVersion', '')))

def rename_with_flags(a, b, flags):
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    call = library.renameatx_np
    call.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    call.restype = ctypes.c_int
    if call(-2, os.fsencode(a), -2, os.fsencode(b), flags) != 0: # AT_FDCWD
        number = ctypes.get_errno(); raise OSError(number, os.strerror(number))

def swap(a, b):
    rename_with_flags(a, b, 2) # RENAME_SWAP

def rename_exclusive(a, b):
    rename_with_flags(a, b, 4) # RENAME_EXCL

def write_json(path, value):
    fd, temporary = tempfile.mkstemp(prefix='.DeskCapture-receipt-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            json.dump(value, file); file.flush(); os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)

def recover(parent, destination, describe=signature):
    for journal in parent.glob('.DeskCapture-install-*.json'):
        if journal.is_symlink() or journal.stat().st_size > 65536:
            raise ValueError('Invalid install receipt; preserved for inspection.')
        record = json.loads(journal.read_text())
        identity = str(uuid.UUID(record['id']))
        if journal.name != '.DeskCapture-install-' + identity + '.json':
            raise ValueError('Install receipt identity mismatch; no paths changed.')
        if record['destination'] != destination.name: continue
        stage = parent / ('.DeskCapture-install-' + identity + '.app')
        backup = parent / '.DeskCapture-install-backups' / identity / 'DeskCapture.app'
        if stage.is_symlink() or backup.is_symlink() or backup.parent.is_symlink() or backup.parent.parent.is_symlink():
            raise ValueError('Install recovery path cannot be a symbolic link.')
        current = describe(destination) if destination.exists() else None
        staged = describe(stage) if stage.exists() else None
        archived = describe(backup) if backup.exists() else None
        if current == record['old'] and staged == record['new'] and archived is None:
            # Prepared but not swapped, or a successful rollback. Keep the signed
            # staged candidate instead of deleting it during crash recovery.
            journal.unlink()
        elif current == record['new'] and staged == record['old'] and archived is None:
            backup.parent.mkdir(parents=True, exist_ok=True); os.rename(stage, backup); journal.unlink()
        elif current == record['new'] and staged is None and archived == record['old']:
            journal.unlink()
        else:
            raise ValueError('Ambiguous install recovery state; all bundles and receipt were preserved.')

def install(source, destination, describe=signature, copy=None, before_swap=None, after_swap=None):
    source, destination = pathlib.Path(source).absolute(), pathlib.Path(destination).absolute()
    if source.is_symlink() or destination.is_symlink() or source == destination or source.suffix != '.app' or destination.suffix != '.app':
        raise ValueError('Use distinct real application bundles.')
    if destination.exists() and os.path.samefile(source, destination): raise ValueError('Source and destination refer to the same bundle.')
    parent = destination.parent; parent.mkdir(parents=True, exist_ok=True)
    lock_path = parent / '.DeskCapture-install.lock'
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        recover(parent, destination, describe)
        new = describe(source); old = describe(destination) if destination.exists() else None
        if old and old['team'] != new['team']:
            raise ValueError('Update team differs from the installed application.')
        identity = str(uuid.uuid4()); stage = parent / ('.DeskCapture-install-' + identity + '.app')
        backup = parent / '.DeskCapture-install-backups' / identity / 'DeskCapture.app'
        journal = parent / ('.DeskCapture-install-' + identity + '.json')
        if backup.parent.parent.is_symlink(): raise ValueError('Backup root cannot be a symbolic link.')
        swapped = False; keep_stage = False
        try:
            if copy: copy(source, stage)
            else: subprocess.run(['/usr/bin/ditto', str(source), str(stage)], check=True)
            if describe(stage) != new or describe(source) != new:
                raise ValueError('Candidate changed during copying.')
            if old and describe(destination) != old:
                raise ValueError('Installed application changed during preparation.')
            if before_swap: before_swap(stage)
            # Hooks/long verification must not leave an unchecked candidate.
            if describe(stage) != new:
                raise ValueError('Candidate changed before commit.')
            if old:
                if describe(destination) != old: raise ValueError('Installed application changed before commit.')
                write_json(journal, dict(id=identity, destination=destination.name, old=old, new=new))
                swap(stage, destination); swapped = True
            else: rename_exclusive(stage, destination); swapped = True
            if after_swap: after_swap(destination)
            if describe(destination) != new: raise ValueError('Installed signature changed after commit.')
            if old:
                backup.parent.mkdir(parents=True, exist_ok=True); os.rename(stage, backup)
                # Both bundles are safely placed. Receipt cleanup failure is not
                # an install failure; next invocation recognizes this state.
                try: journal.unlink()
                except OSError: pass
            return backup if old else None
        except BaseException:
            if swapped:
                try:
                    if old: swap(stage, destination)
                    else: os.rename(destination, stage)
                    swapped = False
                except BaseException:
                    keep_stage = True
                    raise RuntimeError('Rollback could not finish; application bundles and receipt retained at ' + str(parent))
            if not swapped:
                try: journal.unlink(missing_ok=True)
                except OSError: pass
            raise
        finally:
            if stage.exists() and not keep_stage:
                # Stage contains only our copied candidate after no swap/rollback.
                import shutil
                shutil.rmtree(stage)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source'); parser.add_argument('destination'); args = parser.parse_args()
    backup = install(args.source, args.destination)
    print('Installed:', args.destination)
    if backup: print('Previous signed app preserved:', backup)
