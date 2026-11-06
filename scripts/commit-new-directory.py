#!/usr/bin/env python3
import importlib.util, pathlib, sys
spec = importlib.util.spec_from_file_location('safe_app_install', pathlib.Path(__file__).with_name('safe-app-install.py'))
transaction = importlib.util.module_from_spec(spec); spec.loader.exec_module(transaction)
source, destination = map(pathlib.Path, sys.argv[1:3])
if source.is_symlink() or not source.is_dir() or source.parent.resolve().stat().st_dev != destination.parent.resolve().stat().st_dev:
    raise SystemExit('Commit requires a real staged folder on the destination filesystem.')
transaction.rename_exclusive(source, destination)
