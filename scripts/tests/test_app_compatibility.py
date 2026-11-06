import importlib.util
import json
import pathlib
import plistlib
import struct
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('package_compatibility', pathlib.Path(__file__).parents[1] / 'audit-app-compatibility.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)

def binary(cpu=0x0100000C, major=15, platform=1, dependencies=()):
    command = struct.pack('<IIIIII', 0x32, 24, platform, major << 16, 27 << 16, 0)
    for dependency in dependencies:
        name = dependency.encode() + b'\0'; size = (24 + len(name) + 7) // 8 * 8
        command += struct.pack('<IIIIII', 0xC, size, 24, 0, 0, 0) + name + bytes(size - 24 - len(name))
    return struct.pack('<IIIIIIII', 0xFEEDFACF, cpu, 0, 2, 1 + len(dependencies), len(command), 0, 0) + command

class PackageCompatibilityTests(unittest.TestCase):
    def sparkle(self, app):
        framework = app / 'Contents/Frameworks/Sparkle.framework'
        info = framework / 'Versions/B/Resources/Info.plist'; info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.sparkle-project.Sparkle', CFBundleShortVersionString='2.10.0')))
        for suffix in ['Sparkle', 'Autoupdate', 'Updater.app/Contents/MacOS/Updater', 'XPCServices/Downloader.xpc/Contents/MacOS/Downloader', 'XPCServices/Installer.xpc/Contents/MacOS/Installer']:
            file = framework / 'Versions/B' / suffix; file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(binary(major=12)); file.chmod(0o700)
        (framework / 'Versions/Current').symlink_to('B')
        (framework / 'Sparkle').symlink_to('Versions/Current/Sparkle')
        (app / 'Contents/MacOS/DeskCapture').write_bytes(binary(dependencies=['@rpath/Sparkle.framework/Versions/B/Sparkle']))
        return framework
    def bundle(self, root):
        app = pathlib.Path(root) / 'DeskCapture.app'
        info = dict(CFBundleIdentifier='app.monoware.shotloom', CFBundleExecutable='DeskCapture', LSMinimumSystemVersion='15.0',
                    NSCameraUsageDescription='Camera purpose', NSMicrophoneUsageDescription='Microphone purpose', NSScreenCaptureUsageDescription='Screen purpose')
        (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
        for name in ('Contents/MacOS/DeskCapture', 'Contents/Resources/SpeechRuntime/whisper-cli', 'Contents/Resources/VoiceRuntime/desk-voice'):
            file = app / name; file.parent.mkdir(parents=True, exist_ok=True); file.write_bytes(binary()); file.chmod(0o700)
        metadata = app / "Contents/Resources/Metadata.appintents/extract.actionsdata"
        metadata.parent.mkdir(parents=True); metadata.write_text(json.dumps(dict(actions={"OpenDeskCaptureWorkflowIntent": {}}, autoShortcuts=[{"actionIdentifier": "OpenDeskCaptureWorkflowIntent"}])))
        return app
    def test_minimum_os_and_architecture_are_parsed_per_slice(self):
        self.assertEqual(audit.macho(binary())[0]['minimum'], [15, 0, 0])
        arm, intel = binary(), binary(cpu=0x01000007)
        header = struct.pack('>II', 0xCAFEBABE, 2)
        table = struct.pack('>IIIII', 0x0100000C, 0, 48, len(arm), 0) + struct.pack('>IIIII', 0x01000007, 0, 48 + len(arm), len(intel), 0)
        self.assertEqual({item['architecture'] for item in audit.macho(header + table + arm + intel)}, {'arm64', 'x86_64'})
        overlapping = header + table[:20] + struct.pack('>IIIII', 0x01000007, 0, 48, len(intel), 0) + arm + intel
        with self.assertRaises(ValueError): audit.macho(overlapping)
    def test_truncated_wrong_platform_and_malformed_commands_are_rejected(self):
        for data in (binary()[:35], binary(platform=2), b'not executable', binary()[:36] + struct.pack('<I', 1000) + binary()[40:]):
            with self.assertRaises(ValueError): audit.macho(data)
    def test_package_audit_is_explicitly_static_and_does_not_run_binaries(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.bundle(root)
            report = audit.audit(app)
            self.assertTrue(report['success']); self.assertFalse(report['runtimeVerified'])
            self.assertEqual(len(report['binaries']), 3)
    def test_newer_helper_os_and_wrong_architecture_cannot_hide_behind_plist(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.bundle(root); helper = app / 'Contents/Resources/SpeechRuntime/whisper-cli'
            helper.write_bytes(binary(major=26))
            with self.assertRaisesRegex(ValueError, 'minimum OS'): audit.audit(app)
            helper.write_bytes(binary(cpu=0x01000007))
            with self.assertRaisesRegex(ValueError, 'architecture mismatch'): audit.audit(app)
    def test_missing_runtime_and_symbolic_runtime_are_rejected_without_touching_target(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.bundle(root); helper = app / 'Contents/Resources/VoiceRuntime/desk-voice'
            original = helper.read_bytes(); helper.unlink()
            with self.assertRaises(ValueError): audit.audit(app)
            outside = pathlib.Path(root) / 'outside'; outside.write_bytes(original); outside.chmod(0o700); helper.symlink_to(outside)
            with self.assertRaises(ValueError): audit.audit(app)
            self.assertEqual(outside.read_bytes(), original)
    def test_missing_privacy_description_is_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.bundle(root); file = app / 'Contents/Info.plist'; info = plistlib.loads(file.read_bytes())
            del info['NSCameraUsageDescription']; file.write_bytes(plistlib.dumps(info))
            with self.assertRaisesRegex(ValueError, 'privacy purpose'): audit.audit(app)

    def test_missing_native_shortcut_metadata_is_not_a_discoverable_package(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.bundle(root); metadata = app / 'Contents/Resources/Metadata.appintents/extract.actionsdata'
            metadata.unlink()
            with self.assertRaisesRegex(ValueError, 'metadata'): audit.audit(app)

    def test_sparkle_dependency_requires_complete_pinned_framework_and_matching_architectures(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.bundle(root); framework = self.sparkle(app)
            self.assertEqual(len(audit.audit(app)['binaries']), 8)
            installer = framework / 'Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer'
            installer.write_bytes(binary(cpu=0x01000007, major=12))
            with self.assertRaisesRegex(ValueError, 'architecture'): audit.audit(app)
            installer.unlink()
            with self.assertRaisesRegex(ValueError, 'runtime missing'): audit.audit(app)

    def test_unbundled_dependencies_and_framework_symlink_escape_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.bundle(root)
            (app / 'Contents/MacOS/DeskCapture').write_bytes(binary(dependencies=['@rpath/Unexpected.framework/Unexpected']))
            with self.assertRaisesRegex(ValueError, 'unbundled'): audit.audit(app)
            framework = self.sparkle(app)
            outside = pathlib.Path(root) / 'outside'; outside.write_bytes(b'preserve')
            (framework / 'Escape').symlink_to(outside)
            with self.assertRaisesRegex(ValueError, 'escapes'): audit.audit(app)
            self.assertEqual(outside.read_bytes(), b'preserve')

    def test_wrong_sparkle_version_or_missing_framework_cannot_pass_static_preflight(self):
        with tempfile.TemporaryDirectory() as root:
            app = self.bundle(root); framework = self.sparkle(app)
            info = framework / 'Versions/B/Resources/Info.plist'
            info.write_bytes(plistlib.dumps(dict(CFBundleIdentifier='org.sparkle-project.Sparkle', CFBundleShortVersionString='0.0.0')))
            with self.assertRaisesRegex(ValueError, 'version'): audit.audit(app)
        with tempfile.TemporaryDirectory() as root:
            app = self.bundle(root)
            (app / 'Contents/MacOS/DeskCapture').write_bytes(binary(dependencies=['@rpath/Sparkle.framework/Versions/B/Sparkle']))
            with self.assertRaisesRegex(ValueError, 'mismatch'): audit.audit(app)

if __name__ == '__main__': unittest.main()
