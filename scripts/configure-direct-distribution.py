#!/usr/bin/env python3
"""Prepare public metadata for a direct preview, without editing source plists.

Payment onboarding, license enforcement and a production checkout are not yet
connected. Never represent this candidate as a commercial release.
"""
import argparse
import importlib.util
import json
import os
import pathlib
import plistlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]


def prepare(destination, version=None, build=None):
    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    store = plistlib.loads((ROOT / 'Resources/Info-AppStore.plist').read_bytes())
    version = version or store['CFBundleShortVersionString']
    if re.fullmatch(r'[0-9]+\.[0-9]+', version):
        version += '.0'
    build = build or str(store['CFBundleVersion'])
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
        raise ValueError('Direct version must contain three numeric components.')
    if not re.fullmatch(r'[0-9]+', build):
        raise ValueError('Direct build must be numeric.')
    info.update(CFBundleName='Shotloom', CFBundleDisplayName='Shotloom',
                CFBundleIdentifier='com.monoware.shotloom.direct',
                CFBundleExecutable='DeskCapture', CFBundleShortVersionString=version,
                CFBundleVersion=build, ShotloomDistributionChannel='direct',
                ShotloomReleaseStage='preview', LSApplicationCategoryType='public.app-category.utilities',
                NSHumanReadableCopyright='2026 MonoWare')
    # Separate TCC/signature identity and preferences from TestFlight/App Store.
    # Project formats stay compatible; legacy URLs aren't registered by previews.
    info['CFBundleURLTypes'] = [{
        'CFBundleURLName': 'com.monoware.shotloom.direct.actions',
        'CFBundleURLSchemes': ['shotloom-direct'],
    }]
    for item in info.get('CFBundleDocumentTypes', []):
        item['LSHandlerRank'] = 'Alternate'
    for item in info.get('CFBundleDocumentTypes', []):
        item['CFBundleTypeName'] = item['CFBundleTypeName'].replace('DeskCapture', 'Shotloom')
    for item in info.get('UTExportedTypeDeclarations', []):
        item['UTTypeDescription'] = item['UTTypeDescription'].replace('DeskCapture', 'Shotloom')

    spec = importlib.util.spec_from_file_location('update_configuration', ROOT / 'scripts/configure-updates.py')
    updates = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(updates)
    info = updates.prepare(info, os.environ)
    updates.configured(info)
    destination.mkdir(parents=True, exist_ok=True)
    (destination / 'Info.plist').write_bytes(plistlib.dumps(info, sort_keys=False))
    # No fictitious checkout, credentials, price or trial term. The app does not
    # read this as an entitlement or unlock based on this file.
    (destination / 'distribution.json').write_text(json.dumps({
        'schema': 1, 'product': 'shotloom', 'channel': 'direct', 'stage': 'preview',
        'version': version, 'build': build, 'paymentProvider': None,
        'checkoutURL': None, 'licenseEnforcement': False,
        'commercialReleaseReady': False,
    }, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=pathlib.Path)
    parser.add_argument('--version')
    parser.add_argument('--build')
    args = parser.parse_args()
    prepare(args.destination, args.version, args.build)
