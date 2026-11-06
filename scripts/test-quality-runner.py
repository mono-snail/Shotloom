"""Regression for report isolation; no app/device/clipboard access."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

MONITOR = Path(__file__).with_name('monitor-quality.py').resolve()

class ReportIsolationTests(unittest.TestCase):
    def fake_environment(self, root):
        binary = root / 'bin'; binary.mkdir()
        fake = binary / 'pgrep'; fake.write_text('#!/bin/sh\nexit 1\n'); fake.chmod(0o700)
        return dict(os.environ, PATH=str(binary)+os.pathsep+os.environ['PATH'])

    def test_ignores_foreign_finished_report(self):
        with tempfile.TemporaryDirectory(prefix='deskcapture-monitor-test-') as directory:
            root=Path(directory); environment=self.fake_environment(root)
            report=root/'deskcapture-quality-diagnostic.json'
            report.write_text(json.dumps({'runID':'foreign','finished':True,'success':False}))
            process=subprocess.Popen(['python3',str(MONITOR),str(root),'owned'],env=environment,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            try:
                time.sleep(.2)
                self.assertIsNone(process.poll(), 'Foreign report must not finish this run')
                report.write_text(json.dumps({'runID':'owned','finished':True,'success':True,'cases':[]}))
                output,error=process.communicate(timeout=5)
                self.assertEqual(process.returncode,0,error+output)
                self.assertTrue((root/'deskcapture-quality-performance.json').is_file())
            finally:
                if process.poll() is None: process.terminate(); process.communicate(timeout=5)

    def test_own_failure_remains_failure(self):
        with tempfile.TemporaryDirectory(prefix='deskcapture-monitor-test-') as directory:
            root=Path(directory); environment=self.fake_environment(root)
            (root/'deskcapture-quality-diagnostic.json').write_text(json.dumps({'runID':'owned','finished':True,'success':False,'cases':[]}))
            result=subprocess.run(['python3',str(MONITOR),str(root),'owned'],env=environment,capture_output=True,text=True,timeout=5)
            self.assertEqual(result.returncode,1)
            self.assertTrue((root/'deskcapture-quality-performance.json').is_file())

if __name__=='__main__': unittest.main()
