import hashlib
import importlib.util
import json
import pathlib
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('current_quality', pathlib.Path(__file__).parents[1] / 'require-current-quality.py')
quality = importlib.util.module_from_spec(spec); spec.loader.exec_module(quality)

class CurrentQualityEvidenceTests(unittest.TestCase):
    def fixture(self, root):
        app = pathlib.Path(root) / 'DeskCapture.app'; (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/MacOS/DeskCapture').write_bytes(b'fixture binary identity only; never executed')
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleShortVersionString='1.2.3', CFBundleVersion='45')))
        digest = hashlib.sha256((app / 'Contents/MacOS/DeskCapture').read_bytes()).hexdigest()
        data = dict(finished=True, success=True, scope='full', version='1.2.3', build='45', executableSHA256=digest,
                    cases=[dict(case=name, success=True) for name in sorted(quality.REQUIRED_CASES)])
        report = pathlib.Path(root) / 'quality.json'; report.write_text(json.dumps(data))
        return app, report, data
    def test_report_must_match_exact_binary_and_version(self):
        with tempfile.TemporaryDirectory() as root:
            app, report, data = self.fixture(root); self.assertEqual(quality.verify(app, report), data['executableSHA256'])
            (app / 'Contents/MacOS/DeskCapture').write_bytes(b'different binary with identical marketing version')
            with self.assertRaisesRegex(ValueError, 'different executable'): quality.verify(app, report)
    def test_filtered_or_incomplete_case_set_cannot_be_release_evidence(self):
        with tempfile.TemporaryDirectory() as root:
            app, report, data = self.fixture(root)
            data['scope'] = 'long-recording-resources-only'; report.write_text(json.dumps(data))
            with self.assertRaises(ValueError): quality.verify(app, report)
            data['scope'] = 'full'; data['cases'].pop(); report.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'case set'): quality.verify(app, report)
    def test_failed_or_duplicate_cases_are_rejected(self):
        with tempfile.TemporaryDirectory() as root:
            app, report, data = self.fixture(root)
            data['cases'][0]['success'] = False; report.write_text(json.dumps(data))
            with self.assertRaises(ValueError): quality.verify(app, report)
            data['cases'][0]['success'] = True; data['cases'].append(data['cases'][0]); report.write_text(json.dumps(data))
            with self.assertRaisesRegex(ValueError, 'duplicated'): quality.verify(app, report)

if __name__ == '__main__': unittest.main()
