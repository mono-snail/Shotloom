import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


class QualityMonitorTests(unittest.TestCase):
    def test_reports_every_completed_case_when_several_finish_between_polls(self):
        monitor = Path(__file__).resolve().parents[1] / 'monitor-quality.py'
        with tempfile.TemporaryDirectory(prefix='DeskCapture-monitor-test-') as directory:
            root = Path(directory)
            cases = [{'case': 'first-failure', 'success': False},
                     {'case': 'second-pass', 'success': True}]
            (root / 'deskcapture-quality-diagnostic.json').write_text(json.dumps({
                'runID': 'monitor-unit-owned-fixture', 'finished': True,
                'success': False, 'cases': cases}))
            result = subprocess.run([sys.executable, str(monitor), directory,
                                     'monitor-unit-owned-fixture', '5'],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            reported = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
            self.assertEqual(reported, cases)


if __name__ == '__main__':
    unittest.main()
