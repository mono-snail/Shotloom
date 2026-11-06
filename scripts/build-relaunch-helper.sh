#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_dir="$1"
identity="$2"
signing_timestamp="${3:-none}"
distribution="${4:-app-store}"
case "$distribution" in
  app-store) entitlement_flags=(--entitlements Resources/AppStoreHelper.entitlements) ;;
  direct) entitlement_flags=() ;;
  *) print -u2 'Helper distribution must be app-store or direct'; exit 2 ;;
esac
case "$signing_timestamp" in
  none) timestamp_flags=(--timestamp=none) ;;
  required) timestamp_flags=(--timestamp) ;;
  *) print -u2 'Timestamp must be none or required'; exit 2 ;;
esac
helper_dir="$app_dir/Contents/Helpers"
mkdir -p "$helper_dir"
xcrun swiftc -O -target arm64-apple-macos15.0 scripts/helpers/PermissionRelaunch.swift -o "$helper_dir/ShotloomRelaunch"
/usr/bin/codesign --force --sign "$identity" "${timestamp_flags[@]}" --options runtime "${entitlement_flags[@]}" "$helper_dir/ShotloomRelaunch"
