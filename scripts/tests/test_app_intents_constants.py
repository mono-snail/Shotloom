import importlib.util
import json
import pathlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('intent_constants', pathlib.Path(__file__).parents[1] / 'prepare-intent-constants.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class IntentConstantsTests(unittest.TestCase):
    def fixture(self, root):
        source = root / 'Sources/DeskCapture/WorkflowAppIntents.swift'
        source.parent.mkdir(parents=True)
        source.write_text('// owned compiler fixture')
        objects = root / 'objects'
        objects.mkdir()
        rows = [{'typeName': name, 'file': str(source), 'conformances': [protocol]}
                for name, protocol in [('DeskCapture.OpenDeskCaptureWorkflowIntent', 'AppIntents.AppIntent'),
                                       ('DeskCapture.DeskCaptureAppShortcuts', 'AppIntents.AppShortcutsProvider')]]
        return source, objects, rows

    def test_debug_per_file_and_release_aggregate_both_prepare_metadata_inputs(self):
        for filename in ['WorkflowAppIntents.swiftconstvalues', 'DeskCapture-primary.swiftconstvalues']:
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                source, objects, rows = self.fixture(root)
                constants = objects / filename
                constants.write_text(json.dumps(rows))
                module.prepare(root, objects, root / 'work')
                self.assertEqual((root / 'work/constants.txt').read_text(), str(constants.resolve()) + '\n')
                self.assertEqual((root / 'work/sources.txt').read_text(), str(source.resolve()) + '\n')

    def test_missing_provider_and_wrong_checkout_are_rejected(self):
        for problem in ['missing', 'checkout', 'protocol']:
            with self.subTest(problem=problem), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                source, objects, rows = self.fixture(root)
                if problem == 'missing':
                    rows.pop()
                elif problem == 'checkout':
                    rows[0]['file'] = str(root / 'other/WorkflowAppIntents.swift')
                else:
                    rows[0]['conformances'] = []
                (objects / 'DeskCapture-primary.swiftconstvalues').write_text(json.dumps(rows))
                with self.assertRaises(ValueError):
                    module.prepare(root, objects, root / 'work')
                self.assertFalse((root / 'work/constants.txt').exists())
