#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
mkdir -p build
build_lock="$PWD/build/.quality-lock"
build_owns_lock=0
build_owner="${DESKCAPTURE_QUALITY_OWNER_PID:-}"
source scripts/build-lock.sh
deskcapture_acquire_build_lock "$build_lock" "$build_owner"
app_stage=""
trap '[[ -z "$app_stage" ]] || rm -rf "$app_stage"; if (( build_owns_lock )); then rm -f "$build_lock/pid"; rmdir "$build_lock" 2>/dev/null || true; fi' EXIT
zsh scripts/build-speech-runtime.sh
zsh scripts/build-voice-runtime.sh
swift build -c "$configuration"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_stage="$(mktemp -d "$PWD/build/app-stage.XXXXXX")"
app_dir="$app_stage/DeskCapture.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
swift scripts/make-icon.swift "$PWD"
/usr/bin/iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
cp "$binary_dir/DeskCapture" "$app_dir/Contents/MacOS/DeskCapture"
# SwiftPM resources must travel with the signed app, including the workflow example.
[[ -d "$binary_dir/DeskCapture_DeskCapture.bundle" ]] || { print -u2 "Workflow resource bundle is missing."; exit 1; }
/usr/bin/ditto "$binary_dir/DeskCapture_DeskCapture.bundle" "$app_dir/Contents/Resources/DeskCapture_DeskCapture.bundle"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
# macOS permission prompts read the application bundle, not the SwiftPM resource bundle.
for language in en zh-Hans; do
  /usr/bin/ditto "Sources/DeskCapture/Resources/$language.lproj" "$app_dir/Contents/Resources/$language.lproj"
done
python3 scripts/configure-updates.py "$app_dir/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then
  cp Resources/AppIcon.icns "$app_dir/Contents/Resources/AppIcon.icns"
fi
identity="${DESKCAPTURE_SIGN_IDENTITY:-}"
signing_timestamp="${DESKCAPTURE_SIGN_TIMESTAMP:-none}"
case "$signing_timestamp" in
  none) timestamp_flags=(--timestamp=none) ;;
  required) timestamp_flags=(--timestamp) ;;
  *) print -u2 "DESKCAPTURE_SIGN_TIMESTAMP must be none or required"; exit 1 ;;
esac
if [[ -z "$identity" ]]; then
  # Certificate names can repeat after renewal; codesign needs an unambiguous
  # identity even when both certificates are currently valid.
  identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')"
fi
if [[ -z "$identity" ]]; then
  print -u2 "No development certificate found. Set DESKCAPTURE_SIGN_IDENTITY to a signing identity."
  exit 1
fi
zsh scripts/build-relaunch-helper.sh "$app_dir" "$identity" "$signing_timestamp" direct
python3 scripts/embed-sparkle.py "$app_dir" --identity "$identity" --timestamp "$signing_timestamp"
zsh scripts/build-app-intents.sh "$configuration" "$app_dir/Contents/Resources"
mkdir -p "$app_dir/Contents/Resources/SpeechRuntime"
cp build/whisper-runtime/bin/whisper-cli "$app_dir/Contents/Resources/SpeechRuntime/whisper-cli"
cp build/speech-licenses/* "$app_dir/Contents/Resources/SpeechRuntime/"
/usr/bin/codesign --force --sign "$identity" "${timestamp_flags[@]}" --options runtime "$app_dir/Contents/Resources/SpeechRuntime/whisper-cli"
mkdir -p "$app_dir/Contents/Resources/VoiceRuntime"
cp build/voice-runtime/desk-voice build/voice-runtime/*COPYING.txt build/voice-runtime/*NOTICES.txt "$app_dir/Contents/Resources/VoiceRuntime/"
/usr/bin/codesign --force --sign "$identity" "${timestamp_flags[@]}" --options runtime "$app_dir/Contents/Resources/VoiceRuntime/desk-voice"
/usr/bin/codesign --force --sign "$identity" --identifier app.monoware.shotloom "${timestamp_flags[@]}" --options runtime --entitlements Resources/Entitlements.plist "$app_dir"
/usr/bin/codesign --verify --deep --strict "$app_dir"
python3 scripts/audit-app-compatibility.py "$app_dir" --output build/build-compatibility-audit.json
python3 scripts/safe-app-install.py "$app_dir" "$PWD/build/DeskCapture.app"
print "Built: $PWD/build/DeskCapture.app"
