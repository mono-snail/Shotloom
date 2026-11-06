#!/bin/zsh
# Xcode build phase. Uses prepared local binaries; never downloads models or runs tests.
set -euo pipefail
cd "$SRCROOT"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$resources/SpeechRuntime" "$resources/VoiceRuntime"
cp build/whisper-runtime/bin/whisper-cli "$resources/SpeechRuntime/whisper-cli"
cp build/speech-licenses/* "$resources/SpeechRuntime/"
cp build/voice-runtime/desk-voice build/voice-runtime/*COPYING.txt build/voice-runtime/*NOTICES.txt "$resources/VoiceRuntime/"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES ]]; then
    [[ -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]] || { print -u2 'A signing identity is required for sandbox helpers.'; exit 2; }
    for helper in "$resources/SpeechRuntime/whisper-cli" "$resources/VoiceRuntime/desk-voice"; do
        /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --timestamp=none --entitlements Resources/AppStoreHelper.entitlements "$helper"
    done
fi

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == YES ]]; then
    zsh scripts/build-relaunch-helper.sh "$TARGET_BUILD_DIR/$WRAPPER_NAME" "$EXPANDED_CODE_SIGN_IDENTITY"
fi
