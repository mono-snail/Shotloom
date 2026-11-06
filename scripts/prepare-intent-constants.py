#!/usr/bin/env python3
"""Validate compiler App Intents constants in per-file and WMO configurations."""
import json
import pathlib
import sys


def prepare(root, objects, work):
    root, objects, work = map(pathlib.Path, (root, objects, work))
    expected_source = (root / 'Sources/DeskCapture/WorkflowAppIntents.swift').resolve()
    required = {
        'DeskCapture.OpenDeskCaptureWorkflowIntent': 'AppIntents.AppIntent',
        'DeskCapture.DeskCaptureAppShortcuts': 'AppIntents.AppShortcutsProvider',
    }
    values = sorted(objects.glob('*.swiftconstvalues'))
    found = set()
    if not values or len(values) > 1000:
        raise ValueError('Current compiled App Intents constants are missing or exceed limits.')
    for file in values:
        if file.stat().st_size > 16_000_000:
            raise ValueError('Compiled constants exceed the metadata budget.')
        rows = json.loads(file.read_text())
        if not isinstance(rows, list):
            raise ValueError('Invalid compiler constants schema.')
        for row in rows:
            if not isinstance(row, dict):
                raise ValueError('Invalid compiler constant entry.')
            name = row.get('typeName')
            if name in required:
                if pathlib.Path(row.get('file', '')).resolve() != expected_source:
                    raise ValueError('App Intents constants belong to a different source checkout.')
                if required[name] not in row.get('conformances', []):
                    raise ValueError('Compiled intent/provider protocol is missing.')
                found.add(name)
    if found != set(required):
        raise ValueError('Current compiled workflow intent/provider constants are missing.')
    sources = sorted((root / 'Sources/DeskCapture').glob('*.swift'))
    if not expected_source.is_file() or not sources:
        raise ValueError('Current intent source is missing.')
    work.mkdir(parents=True, exist_ok=True)
    (work / 'sources.txt').write_text(''.join(str(file.resolve()) + '\n' for file in sources))
    (work / 'constants.txt').write_text(''.join(str(file.resolve()) + '\n' for file in values))


if __name__ == '__main__':
    prepare(*sys.argv[1:])
