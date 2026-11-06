#!/bin/zsh
# Build and sign a private website candidate. No install, launch, tests,
# diagnostics, notarization upload, dependency download or website publication.
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) print -u2 'Use debug or release.'; exit 2 ;; esac
mkdir -p build/direct
build_lock="$PWD/build/.quality-lock"
build_owns_lock=0
source scripts/build-lock.sh
deskcapture_acquire_build_lock "$build_lock" ""
stage=""
trap '[[ -z "$stage" ]] || rm -rf "$stage"; if (( build_owns_lock )); then rm -f "$build_lock/pid"; rmdir "$build_lock" 2>/dev/null || true; fi' EXIT

# Reuse already built local runtimes; a missing cache is a blocker, never an
# invitation to invoke the legacy fetch/build scripts.
for cached in build/whisper-runtime/bin/whisper-cli build/voice-runtime/desk-voice \
  build/speech-licenses/whisper.cpp-LICENSE build/speech-licenses/ggml-LICENSE \
  build/speech-licenses/miniaudio-NOTICE.txt build/speech-licenses/stb-vorbis-NOTICE.txt \
  build/voice-runtime/RNNoise-COPYING.txt build/voice-runtime/libebur128-COPYING.txt \
  build/voice-runtime/RNNoise-SOURCE-NOTICES.txt \
  .build/artifacts/deskcapture/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Sparkle; do
  [[ -f "$cached" ]] || { print -u2 "Missing cached dependency: $cached. No download started."; exit 2; }
done
identity="${DESKCAPTURE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="$(security find-identity -v -p codesigning | awk '/"Apple Development:/ { print $2; exit }')"
fi
[[ -n "$identity" ]] || { print -u2 'Set DESKCAPTURE_SIGN_IDENTITY to an existing signing identity.'; exit 2; }
signing_timestamp="${DESKCAPTURE_SIGN_TIMESTAMP:-none}"
case "$signing_timestamp" in
  none) timestamp_flags=(--timestamp=none) ;;
  required) timestamp_flags=(--timestamp) ;;
  *) print -u2 'DESKCAPTURE_SIGN_TIMESTAMP must be none or required.'; exit 2 ;;
esac

stage="$(mktemp -d "$PWD/build/direct/.stage.XXXXXX")"
metadata_args=()
[[ -z "${DESKCAPTURE_DIRECT_VERSION:-}" ]] || metadata_args+=(--version "$DESKCAPTURE_DIRECT_VERSION")
[[ -z "${DESKCAPTURE_DIRECT_BUILD:-}" ]] || metadata_args+=(--build "$DESKCAPTURE_DIRECT_BUILD")
python3 scripts/configure-direct-distribution.py "$stage/metadata" "${metadata_args[@]}"

# SwiftPM must use its existing workspace/artifacts and may not resolve a new
# remote dependency. The explicit condition also excludes future commerce code
# from development and App Store builds.
swift build -c "$configuration" --product DeskCapture --disable-automatic-resolution --skip-update -Xswiftc -DDIRECT_DISTRIBUTION
binary_dir="$(swift build -c "$configuration" --product DeskCapture --disable-automatic-resolution --skip-update --show-bin-path)"
app="$stage/Shotloom.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources"
cp "$binary_dir/DeskCapture" "$app/Contents/MacOS/DeskCapture"
[[ -d "$binary_dir/DeskCapture_DeskCapture.bundle" ]] || { print -u2 'Missing compiled resources.'; exit 2; }
/usr/bin/ditto "$binary_dir/DeskCapture_DeskCapture.bundle" "$resources/DeskCapture_DeskCapture.bundle"
cp "$stage/metadata/Info.plist" "$app/Contents/Info.plist"
cp "$stage/metadata/distribution.json" "$resources/ShotloomDistribution.json"
cp Resources/AppIcon.icns Resources/PrivacyInfo.xcprivacy "$resources/"
for language in en zh-Hans; do
  /usr/bin/ditto "Sources/DeskCapture/Resources/$language.lproj" "$resources/$language.lproj"
done
zsh scripts/build-relaunch-helper.sh "$app" "$identity" "$signing_timestamp" direct
python3 scripts/embed-sparkle.py "$app" --identity "$identity" --timestamp "$signing_timestamp"
zsh scripts/build-app-intents.sh "$configuration" "$resources"
mkdir -p "$resources/SpeechRuntime" "$resources/VoiceRuntime"
cp build/whisper-runtime/bin/whisper-cli build/speech-licenses/* "$resources/SpeechRuntime/"
cp build/voice-runtime/desk-voice build/voice-runtime/*COPYING.txt build/voice-runtime/*NOTICES.txt "$resources/VoiceRuntime/"
for helper in "$resources/SpeechRuntime/whisper-cli" "$resources/VoiceRuntime/desk-voice"; do
  /usr/bin/codesign --force --sign "$identity" "${timestamp_flags[@]}" --options runtime "$helper"
done
/usr/bin/codesign --force --sign "$identity" "${timestamp_flags[@]}" --options runtime \
  --entitlements Resources/Entitlements.plist "$app"
# Signature verification is an integral part of producing the signed bundle;
# no application/functional quality diagnostics are invoked here.
/usr/bin/codesign --verify --deep --strict "$app"
cp "$stage/metadata/distribution.json" "$stage/distribution.json"
rm -rf "$stage/metadata"
output="$PWD/build/direct/candidate-$(date -u +%Y%m%dT%H%M%SZ)-${stage:t}"
mv "$stage" "$output"
stage=""
print "Private preview built: $output/Shotloom.app"
print 'Not installed, notarized or published. Payment, licensing and trial are not enabled.'
