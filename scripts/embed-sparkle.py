#!/usr/bin/env python3
"""Embed the pinned SwiftPM Sparkle artifact and sign nested code inside out."""
import argparse, pathlib, plistlib, shutil, subprocess


def validate_framework(source):
    source = pathlib.Path(source)
    if source.is_symlink() or not source.is_dir(): raise ValueError('Expected a real Sparkle framework directory.')
    canonical = source.resolve()
    for item in source.rglob('*'):
        if item.is_symlink() and (not item.exists() or not item.resolve().is_relative_to(canonical)):
            raise ValueError('Framework symlink escapes its bundle or is broken.')
    info = plistlib.loads((source / 'Versions/B/Resources/Info.plist').read_bytes())
    if (info.get('CFBundleIdentifier'), info.get('CFBundleShortVersionString')) != ('org.sparkle-project.Sparkle', '2.10.0'):
        raise ValueError('Framework does not match pinned Sparkle 2.10.0.')


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('app', type=pathlib.Path)
    parser.add_argument('--identity', required=True); parser.add_argument('--timestamp', choices=['none', 'required'], default='none'); args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parents[1]
    artifact = root / '.build/artifacts/deskcapture/Sparkle'
    source = artifact / 'Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework'
    validate_framework(source)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', str(source)], check=True)
    destination = args.app / 'Contents/Frameworks/Sparkle.framework'
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, destination, symlinks=True)
    license_directory = args.app / 'Contents/Resources/ThirdPartyLicenses'; license_directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(artifact / 'LICENSE', license_directory / 'Sparkle.txt')
    for relative in ['Versions/B/XPCServices/Downloader.xpc', 'Versions/B/XPCServices/Installer.xpc', 'Versions/B/Updater.app', 'Versions/B/Autoupdate', '.']:
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', args.identity, '--timestamp=none' if args.timestamp == 'none' else '--timestamp', '--options', 'runtime', str(destination / relative)], check=True)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', '--all-architectures', str(destination)], check=True)
    print('Embedded and signed pinned Sparkle 2.10.0 with nested helpers.')

if __name__ == '__main__': main()
