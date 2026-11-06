import hashlib
import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest

path = pathlib.Path(__file__).resolve().parents[1] / 'require-long-recording-quality.py'
spec = importlib.util.spec_from_file_location('long_quality', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class LongRecordingQualityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='DeskCapture-owned-long-gate-')
        self.root = pathlib.Path(self.temporary.name)
        self.app = self.root / 'Owned.app'
        (self.app / 'Contents/MacOS').mkdir(parents=True)
        (self.app / 'Contents/MacOS/DeskCapture').write_bytes(b'owned executable')
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleShortVersionString': '0.27.4', 'CFBundleVersion': '41'}))
        self.digest = hashlib.sha256(b'owned executable').hexdigest()
        self.report = self.root / 'report.json'
        self.data = {'finished': True, 'success': True, 'scope': 'long-recording-resources-only',
                     'executableSHA256': self.digest, 'version': '0.27.4', 'build': '41',
                     'cases': [{'case': 'long-recording-resources', 'success': True, 'requestedSeconds': 1800,
                                'durationSeconds': 1800.7, 'cameraEnabled': True, 'cameraDurationSeconds': 1800.6}]}

    def tearDown(self):
        self.temporary.cleanup()

    def verify(self):
        self.report.write_text(json.dumps(self.data))
        return module.verify(self.app, self.report)

    def test_complete_requested_camera_and_explicit_screen_only_are_accepted(self):
        self.assertEqual(self.verify(), self.digest)
        self.data['cases'][0]['cameraEnabled'] = False
        del self.data['cases'][0]['cameraDurationSeconds']
        self.assertEqual(self.verify(), self.digest)

    def test_partial_camera_is_rejected_even_when_raw_resource_report_says_success(self):
        self.data['cases'][0]['cameraDurationSeconds'] = 1013.292
        with self.assertRaisesRegex(ValueError, 'Camera coverage is incomplete'):
            self.verify()
        self.data['cases'][0]['cameraDurationSeconds'] = 1800.6
        self.data['cases'][0]['warning'] = '摄像头已停止输出，屏幕录制继续'
        with self.assertRaisesRegex(ValueError, 'camera interruption'):
            self.verify()

    def test_wrong_identity_scope_and_nonfinite_or_missing_durations_are_rejected(self):
        original = json.loads(json.dumps(self.data))
        for key, value in [('scope', 'full'), ('finished', False), ('executableSHA256', 'old')]:
            self.data = json.loads(json.dumps(original)); self.data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify()
        for key, value in [('requestedSeconds', 60), ('durationSeconds', 1790), ('cameraDurationSeconds', float('nan'))]:
            self.data = json.loads(json.dumps(original)); self.data['cases'][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify()
