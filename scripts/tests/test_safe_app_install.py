import importlib.util
import json
import pathlib
import shutil
import tempfile
import unittest
import plistlib
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('safe_app_install', pathlib.Path(__file__).parents[1] / 'safe-app-install.py')
installer = importlib.util.module_from_spec(spec); spec.loader.exec_module(installer)

def bundle(parent, name, build, team='TESTTEAM01'):
    path = pathlib.Path(parent) / name; path.mkdir()
    (path / 'fixture.json').write_text(json.dumps(dict(team=team, build=str(build), digest='fixture-' + str(build))))
    (path / 'mapped-file').write_text('old bytes' if build == 1 else 'new bytes')
    return path

def describe(path):
    return json.loads((path / 'fixture.json').read_text())

class SafeAppInstallTests(unittest.TestCase):
    def test_atomic_swap_retains_old_inode_and_signed_fixture_backup(self):
        with tempfile.TemporaryDirectory() as root:
            source = bundle(root, 'Candidate.app', 2); destination = bundle(root, 'DeskCapture.app', 1)
            with (destination / 'mapped-file').open() as mapped:
                backup = installer.install(source, destination, describe=describe, copy=shutil.copytree)
                self.assertEqual(mapped.read(), 'old bytes')
            self.assertEqual(describe(destination)['build'], '2'); self.assertEqual(describe(backup)['build'], '1')
            self.assertEqual(describe(source)['build'], '2')
            self.assertFalse(list(pathlib.Path(root).glob('.DeskCapture-install-*.json')))
    def test_failure_after_swap_restores_target_and_leaves_source(self):
        with tempfile.TemporaryDirectory() as root:
            source = bundle(root, 'Candidate.app', 2); destination = bundle(root, 'DeskCapture.app', 1)
            def fail(_): raise OSError('injected post-swap verification failure')
            with self.assertRaises(OSError): installer.install(source, destination, describe=describe, copy=shutil.copytree, after_swap=fail)
            self.assertEqual(describe(destination)['build'], '1'); self.assertEqual(describe(source)['build'], '2')
            self.assertFalse(list(pathlib.Path(root).glob('.DeskCapture-install-*.json')))
    def test_different_team_and_copy_time_mutation_keep_destination(self):
        with tempfile.TemporaryDirectory() as root:
            source = bundle(root, 'Candidate.app', 2, team='OTHERTEAM0'); destination = bundle(root, 'DeskCapture.app', 1)
            with self.assertRaisesRegex(ValueError, 'team differs'): installer.install(source, destination, describe=describe, copy=shutil.copytree)
            (source / 'fixture.json').write_text(json.dumps(dict(team='TESTTEAM01', build='2', digest='fixture-2')))
            def changed(a, b):
                shutil.copytree(a, b); (a / 'fixture.json').write_text(json.dumps(dict(team='TESTTEAM01', build='3', digest='fixture-3')))
            with self.assertRaisesRegex(ValueError, 'changed during copying'): installer.install(source, destination, describe=describe, copy=changed)
            self.assertEqual(describe(destination)['build'], '1')
    def test_crash_after_atomic_swap_recovers_old_bundle_to_backup(self):
        with tempfile.TemporaryDirectory() as root:
            destination = bundle(root, 'DeskCapture.app', 1)
            identity = str(installer.uuid.uuid4()); stage = bundle(root, '.DeskCapture-install-' + identity + '.app', 2)
            record = dict(id=identity, destination=destination.name, old=describe(destination), new=describe(stage))
            journal = pathlib.Path(root) / ('.DeskCapture-install-' + identity + '.json'); installer.write_json(journal, record)
            installer.swap(stage, destination)
            installer.recover(pathlib.Path(root), destination, describe)
            backup = pathlib.Path(root) / '.DeskCapture-install-backups' / identity / 'DeskCapture.app'
            self.assertEqual(describe(destination)['build'], '2'); self.assertEqual(describe(backup)['build'], '1'); self.assertFalse(journal.exists())
    def test_ambiguous_crash_state_preserves_all_files(self):
        with tempfile.TemporaryDirectory() as root:
            destination = bundle(root, 'DeskCapture.app', 1); identity = str(installer.uuid.uuid4())
            stage = bundle(root, '.DeskCapture-install-' + identity + '.app', 3)
            journal = pathlib.Path(root) / ('.DeskCapture-install-' + identity + '.json')
            installer.write_json(journal, dict(id=identity, destination=destination.name, old=describe(destination), new=dict(team='TESTTEAM01', build='2', digest='fixture-2')))
            with self.assertRaisesRegex(ValueError, 'Ambiguous'): installer.recover(pathlib.Path(root), destination, describe)
            self.assertTrue(journal.exists()); self.assertEqual(describe(stage)['build'], '3'); self.assertEqual(describe(destination)['build'], '1')
    def test_inline_requirement_uses_codesign_expression_syntax_and_keeps_identity_policy(self):
        with tempfile.TemporaryDirectory() as root:
            app = pathlib.Path(root) / 'Candidate.app'
            (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleIdentifier=installer.BUNDLE_ID, CFBundleVersion='2')))
            requirements = []
            def codesign(arguments, **kwargs):
                if '--display' in arguments:
                    return installer.subprocess.CompletedProcess(arguments, 0, stderr='TeamIdentifier=TESTTEAM01\nCDHash=' + 'a' * 40 + '\n')
                if '-R' in arguments:
                    value = arguments[arguments.index('-R') + 1]
                    if not value.startswith('='):
                        raise installer.subprocess.CalledProcessError(1, arguments, stderr=b'invalid requirement specification')
                    requirements.append(value)
                return installer.subprocess.CompletedProcess(arguments, 0)
            with patch.object(installer.subprocess, 'run', side_effect=codesign):
                value = installer.signature(app)
            self.assertEqual(value['team'], 'TESTTEAM01')
            self.assertEqual(len(requirements), 1)
            self.assertIn('identifier "app.monoware.shotloom"', requirements[0])
            self.assertIn('anchor apple generic', requirements[0])
            self.assertIn('certificate leaf[subject.OU] = "TESTTEAM01"', requirements[0])
    def test_real_signature_checker_rejects_unsigned_fixture_without_launching_it(self):
        with tempfile.TemporaryDirectory() as root:
            unsigned = bundle(root, 'Unsigned.app', 1)
            with self.assertRaises((installer.subprocess.CalledProcessError, ValueError)): installer.signature(unsigned)
            self.assertTrue((unsigned / 'fixture.json').exists())

if __name__ == '__main__': unittest.main()
