#!/usr/bin/env python3
"""Static package preflight; it is deliberately not an OS/runtime test."""
import argparse, json, pathlib, plistlib, struct, os, tempfile, importlib.util

_updates_spec = importlib.util.spec_from_file_location('deskcapture_update_configuration', pathlib.Path(__file__).with_name('configure-updates.py'))
_updates = importlib.util.module_from_spec(_updates_spec); _updates_spec.loader.exec_module(_updates)

ARCHES = {0x0100000C: 'arm64', 0x01000007: 'x86_64'}

def version(value):
    return (value >> 16, (value >> 8) & 255, value & 255)

def macho(data):
    if len(data) < 8:
        raise ValueError('truncated Mach-O')
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = data[:4] == b'\xca\xfe\xba\xbf'
        count = struct.unpack_from('>I', data, 4)[0]
        stride = 32 if wide else 20
        if not 1 <= count <= 8 or 8 + count * stride > len(data):
            raise ValueError('invalid universal header')
        slices, spans = [], []
        for index in range(count):
            start = 8 + index * stride
            cpu = struct.unpack_from('>I', data, start)[0]
            offset, size = struct.unpack_from('>QQ' if wide else '>II', data, start + 8)
            if size < 32 or offset < 8 + count * stride or offset + size > len(data) or any(offset < b and offset + size > a for a, b in spans):
                raise ValueError('invalid or overlapping universal slices')
            spans.append((offset, offset + size))
            parsed = macho(data[offset:offset + size])
            if len(parsed) != 1 or parsed[0]['cpu'] != cpu:
                raise ValueError('universal CPU mismatch')
            slices += parsed
        if len({item['architecture'] for item in slices}) != len(slices):
            raise ValueError('duplicate architecture')
        return slices
    if data[:4] != b'\xcf\xfa\xed\xfe' or len(data) < 32:
        raise ValueError('unsupported Mach-O format')
    cpu, subtype, kind, count, command_bytes = struct.unpack_from('<IIIII', data, 4)
    if cpu not in ARCHES or kind not in (2, 6, 8) or count > 10000 or 32 + command_bytes > len(data):
        raise ValueError('invalid Mach-O header')
    position, end, minimum, platform, dependencies = 32, 32 + command_bytes, None, None, []
    for _ in range(count):
        if position + 8 > end:
            raise ValueError('truncated load command')
        command, size = struct.unpack_from('<II', data, position)
        if size < 8 or size % 8 or position + size > end:
            raise ValueError('invalid load command size')
        if command == 0x32:  # LC_BUILD_VERSION
            if size < 24 or minimum is not None:
                raise ValueError('invalid build version')
            platform, encoded = struct.unpack_from('<II', data, position + 8)
            tools = struct.unpack_from('<I', data, position + 20)[0]
            if tools > 1000 or 24 + tools * 8 != size:
                raise ValueError('invalid build tool table')
            minimum = version(encoded)
        elif command == 0x24:  # LC_VERSION_MIN_MACOSX
            if size < 16 or minimum is not None:
                raise ValueError('invalid minimum version')
            minimum, platform = version(struct.unpack_from('<I', data, position + 8)[0]), 1
        elif command in (0xC, 0x80000018, 0x8000001F, 0x80000023):
            if size < 24:
                raise ValueError('invalid dylib command')
            offset = struct.unpack_from('<I', data, position + 8)[0]
            if not 24 <= offset < size:
                raise ValueError('invalid dylib path')
            raw = data[position + offset:position + size]
            if b'\0' not in raw:
                raise ValueError('unterminated dylib path')
            dependencies.append(raw.split(b'\0', 1)[0].decode('utf-8'))
        position += size
    if position != end or minimum is None or platform != 1:
        raise ValueError('not a macOS executable with a declared deployment target')
    return [dict(cpu=cpu, architecture=('arm64e' if cpu == 0x0100000C and subtype & 0xFFFFFF == 2 else 'x86_64h' if cpu == 0x01000007 and subtype & 0xFFFFFF == 8 else ARCHES[cpu]), subtype=subtype, minimum=list(minimum), dependencies=dependencies)]

def audit(app):
    app = pathlib.Path(app).absolute()
    if app.is_symlink() or not app.is_dir():
        raise ValueError('app must be a real bundle directory')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'app.monoware.shotloom' or info.get('CFBundleExecutable') != 'DeskCapture':
        raise ValueError('unexpected bundle identity')
    parts = tuple(int(part) for part in info['LSMinimumSystemVersion'].split('.'))
    claimed = (parts + (0, 0, 0))[:3]
    if claimed < (15, 0, 0):
        raise ValueError('package declares an unsupported OS target')
    for key in ('NSCameraUsageDescription', 'NSMicrophoneUsageDescription', 'NSScreenCaptureUsageDescription'):
        if not isinstance(info.get(key), str) or not info[key].strip():
            raise ValueError('missing privacy purpose: ' + key)
    names = ['Contents/MacOS/DeskCapture', 'Contents/Resources/SpeechRuntime/whisper-cli', 'Contents/Resources/VoiceRuntime/desk-voice']
    sparkle_dependency = '@rpath/Sparkle.framework/Versions/B/Sparkle'
    main_dependencies = {dependency for item in macho((app / names[0]).read_bytes()) for dependency in item['dependencies']}
    sparkle = app / 'Contents/Frameworks/Sparkle.framework'
    uses_sparkle = sparkle_dependency in main_dependencies
    if uses_sparkle or sparkle.exists():
        if not uses_sparkle or sparkle.is_symlink() or not sparkle.is_dir():
            raise ValueError('Sparkle dependency/framework mismatch')
        for item in sparkle.rglob('*'):
            if item.is_symlink() and (not item.exists() or not item.resolve().is_relative_to(sparkle.resolve())):
                raise ValueError('Sparkle framework link escapes bundle or is broken')
        sparkle_info = plistlib.loads((sparkle / 'Versions/B/Resources/Info.plist').read_bytes())
        if (sparkle_info.get('CFBundleIdentifier'), sparkle_info.get('CFBundleShortVersionString')) != ('org.sparkle-project.Sparkle', '2.10.0'):
            raise ValueError('Unexpected Sparkle framework version')
        names += ['Contents/Frameworks/Sparkle.framework/' + suffix for suffix in [
            'Versions/B/Sparkle', 'Versions/B/Autoupdate', 'Versions/B/Updater.app/Contents/MacOS/Updater',
            'Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader', 'Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer']]
    updates_configured = _updates.configured(info)
    binaries, expected = [], None
    for name in names:
        file = app / name
        cursor = app
        for part in pathlib.Path(name).parts[:-1]:
            cursor = cursor / part
            if cursor.is_symlink():
                raise ValueError('runtime path uses a symbolic link')
        if file.is_symlink() or not file.is_file() or not os.access(file, os.X_OK) or file.stat().st_size > 300_000_000:
            raise ValueError('runtime missing or invalid: ' + name)
        slices = macho(file.read_bytes())
        arches = {item['architecture'] for item in slices}
        if expected is None:
            expected = arches
        if (name in names[:3] and arches != expected) or (name not in names[:3] and not expected.issubset(arches)):
            raise ValueError('runtime architecture mismatch: ' + name)
        for item in slices:
            if tuple(item['minimum']) > claimed:
                raise ValueError('runtime minimum OS exceeds app declaration: ' + name)
            for dependency in item['dependencies']:
                if not (dependency.startswith('/System/Library/') or dependency.startswith('/usr/lib/') or (dependency.startswith('@rpath/libswift') and dependency.endswith('.dylib')) or (uses_sparkle and dependency == sparkle_dependency)):
                    raise ValueError('unbundled runtime dependency: ' + dependency)
        binaries.append(dict(file=name, slices=slices))
    metadata = app / 'Contents/Resources/Metadata.appintents/extract.actionsdata'
    if metadata.is_symlink() or metadata.parent.is_symlink() or not metadata.is_file() or metadata.stat().st_size > 2_000_000:
        raise ValueError('App Intents metadata missing or invalid')
    actions = json.loads(metadata.read_text())
    if 'OpenDeskCaptureWorkflowIntent' not in actions.get('actions', {}) or not actions.get('autoShortcuts'):
        raise ValueError('Workflow shortcut action is absent from package metadata')
    return dict(scope='static-package-only', runtimeVerified=False, success=True, bundle=str(app), minimumOS=list(claimed), binaries=binaries, updateFeedConfigured=updates_configured,
                limitations=['No installation, permission, API execution or hardware compatibility is proven by this report.'])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app'); parser.add_argument('--output', required=True)
    args = parser.parse_args()
    try:
        report = audit(args.app)
    except (OSError, ValueError, KeyError, UnicodeError, plistlib.InvalidFileException) as error:
        report = dict(scope='static-package-only', runtimeVerified=False, success=False, error=str(error))
    output = pathlib.Path(args.output); output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='.compatibility-', dir=output.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            json.dump(report, file, indent=2, ensure_ascii=False); file.write('\n')
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
    print(json.dumps(report, ensure_ascii=False))
    return 0 if report['success'] else 1

if __name__ == '__main__':
    raise SystemExit(main())
