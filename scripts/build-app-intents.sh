#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-release}"
resources="${2:?Pass the staged app Resources directory}"
intent_arch="${DESKCAPTURE_BUILD_ARCH:-$(uname -m)}"
case "$configuration" in debug) intent_config=Debug ;; release) intent_config=Release ;; *) print -u2 'Unknown build configuration'; exit 2 ;; esac
case "$intent_arch" in arm64|x86_64) ;; *) print -u2 'Unsupported metadata build architecture'; exit 2 ;; esac
intent_objects="$PWD/.build/out/Intermediates.noindex/DeskCapture.build/$intent_config/DeskCapture-p.build/Objects-normal/$intent_arch"
intent_work="$(mktemp -d "$PWD/build/app-intents-stage.XXXXXX")"
trap 'rm -rf "$intent_work"' EXIT
python3 scripts/prepare-intent-constants.py "$PWD" "$intent_objects" "$intent_work"
intent_compiler="$(xcrun --find swiftc)"
intent_toolchain="${intent_compiler:h:h:h}"
intent_sdk="$(xcrun --show-sdk-path)"
intent_xcode="$(xcodebuild -version | awk '/Build version/ {print $3}')"
mkdir -p "$resources"
xcrun appintentsmetadataprocessor --output "$resources" --toolchain-dir "$intent_toolchain" --module-name DeskCapture --sdk-root "$intent_sdk" --xcode-version "$intent_xcode" --platform-family macOS --deployment-target 15.0 --target-triple "$intent_arch-apple-macos15.0" --source-file-list "$intent_work/sources.txt" --swift-const-vals-list "$intent_work/constants.txt"
[[ -s "$resources/Metadata.appintents/extract.actionsdata" ]] || { print -u2 'App Intents metadata was not produced; refusing an undiscoverable shortcut package.'; exit 2; }
