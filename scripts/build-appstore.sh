#!/bin/zsh
# Prepare a separate store archive. No simulator, model download, test, install or upload.
set -euo pipefail
cd "${0:A:h:h}"
mkdir -p build/app-store
store_build="${DESKCAPTURE_STORE_BUILD:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Resources/Info-AppStore.plist)}"
store_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info-AppStore.plist)"
[[ "$store_build" == <-> ]] || { print -u2 'DESKCAPTURE_STORE_BUILD must be numeric'; exit 2; }
archive_path="$PWD/build/app-store/Shotloom-$store_version-$store_build.xcarchive"
build_lock="$PWD/build/.quality-lock"
build_owns_lock=0
source scripts/build-lock.sh
deskcapture_acquire_build_lock "$build_lock" ""
trap 'if (( build_owns_lock )); then rm -f "$build_lock/pid"; rmdir "$build_lock" 2>/dev/null || true; fi' EXIT
for cached in build/r37-whisper-source.tar.gz build/r39-rnnoise-0.2.tar.gz build/r39-rnnoise-data.tar.gz build/r39-ebur128.tar.gz; do
    [[ -f "$cached" ]] || { print -u2 "Missing cached dependency: $cached. No download was started."; exit 2; }
done
[[ ! -e "$archive_path" ]] || { print -u2 'Archive exists; preserve it and increment the build before another archive.'; exit 2; }
zsh scripts/build-speech-runtime.sh
zsh scripts/build-voice-runtime.sh
python3 scripts/generate-store-project.py
xcodebuild archive -project Shotloom.xcodeproj -scheme Shotloom -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$archive_path" \
    -derivedDataPath "$PWD/build/app-store/DerivedData" -allowProvisioningUpdates
