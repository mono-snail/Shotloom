import base64, importlib.util, pathlib, plistlib, subprocess, sys, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('update_config', ROOT / 'scripts/configure-updates.py')
config = importlib.util.module_from_spec(spec); spec.loader.exec_module(config)

class UpdateConfigurationTests(unittest.TestCase):
    def test_absent_is_development_only_and_full_release_requires_public_configuration(self):
        self.assertFalse(config.configured({}))
        with self.assertRaises(ValueError): config.configured({}, require=True)
        info = config.prepare({}, {'DESKCAPTURE_UPDATE_FEED_URL': 'https://updates.example.invalid/feed', 'DESKCAPTURE_UPDATE_PUBLIC_ED_KEY': base64.b64encode(bytes(range(32))).decode()})
        self.assertTrue(config.configured(info, require=True))
        self.assertFalse(info['SUEnableAutomaticChecks']); self.assertFalse(info['SUSendsSystemProfile']); self.assertFalse(info['SUAllowsAutomaticUpdates'])
        for feed in ['http://example.invalid/feed', 'file:///tmp/feed', 'https://user:secret@example.invalid/feed', 'https://example.invalid/feed#part']:
            with self.assertRaises(ValueError): config.configured(dict(info, SUFeedURL=feed))
        for key in ['', 'invalid', base64.b64encode(bytes(32)).decode()]:
            with self.assertRaises(ValueError): config.configured(dict(info, SUPublicEDKey=key))
        for flag in ['SURequireSignedFeed', 'SUVerifyUpdateBeforeExtraction']:
            with self.assertRaises(ValueError): config.configured(dict(info, **{flag:False}))

    def test_failed_cli_configuration_preserves_input_plist(self):
        with tempfile.TemporaryDirectory(prefix='DeskCapture-update-config-') as folder:
            file = pathlib.Path(folder) / 'Info.plist'; original = plistlib.dumps({'SUFeedURL':'http://invalid.example/feed'})
            file.write_bytes(original)
            result = subprocess.run([sys.executable, str(ROOT / 'scripts/configure-updates.py'), str(file)], capture_output=True, env={})
            self.assertNotEqual(result.returncode, 0); self.assertEqual(file.read_bytes(), original)

if __name__ == '__main__': unittest.main()
