import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "build-lock.sh"


class BuildLockTests(unittest.TestCase):
    def acquire(self, lock, inherited=""):
        return subprocess.run(
            ["zsh", "-c", 'source "$1"; deskcapture_acquire_build_lock "$2" "$3"; result=$?; print "owns=$build_owns_lock"; exit $result',
             "lock-test", str(HELPER), str(lock), inherited], capture_output=True, text=True)

    def test_recovers_exited_owner_and_acquires_new_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "lock"
            lock.mkdir()
            exited = subprocess.Popen(["true"])
            exited.wait()
            (lock / "pid").write_text(str(exited.pid))
            result = self.acquire(lock)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("owns=1", result.stdout)
            self.assertNotEqual((lock / "pid").read_text().strip(), str(exited.pid))

    def test_live_owner_remains_protected_and_nested_build_can_reuse(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "lock"
            lock.mkdir()
            owner = str(os.getpid())
            (lock / "pid").write_text(owner)
            self.assertEqual(self.acquire(lock).returncode, 2)
            self.assertEqual((lock / "pid").read_text(), owner)
            nested = self.acquire(lock, owner)
            self.assertEqual(nested.returncode, 0, nested.stderr)
            self.assertIn("owns=0", nested.stdout)

    def test_does_not_remove_initializing_lock(self):
        with tempfile.TemporaryDirectory() as directory:
            lock = Path(directory) / "lock"
            lock.mkdir()
            self.assertEqual(self.acquire(lock).returncode, 2)
            self.assertTrue(lock.is_dir())
