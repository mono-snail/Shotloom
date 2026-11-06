#!/bin/zsh
# Explicit notarization of an already signed candidate; never builds, installs,
# launches the app, runs tests, starts a quality diagnostic, or publishes a URL.
set -euo pipefail
cd "${0:A:h:h}"
candidate="${1:?Pass the private direct Shotloom.app candidate}"
notary_profile="${DESKCAPTURE_NOTARY_PROFILE:-}"
[[ -n "$notary_profile" ]] || { print -u2 'Set an existing DESKCAPTURE_NOTARY_PROFILE.'; exit 2; }
[[ -d "$candidate" && ! -L "$candidate" ]] || { print -u2 'Expected a real app bundle.'; exit 2; }
candidate="${candidate:A}"
[[ "$candidate" == "$PWD/build/direct/"*/Shotloom.app ]] || { print -u2 'Only build/direct candidates are accepted.'; exit 2; }
/usr/bin/codesign --verify --deep --strict "$candidate"
signature="$(/usr/bin/codesign --display --verbose=4 "$candidate" 2>&1)"
[[ "$signature" == *'Authority=Developer ID Application:'* ]] || {
  print -u2 'This candidate needs Developer ID Application signing with secure timestamps. No upload started.'; exit 2;
}
python3 - "$candidate" <<'PY'
import json, pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
metadata = json.loads((app / 'Contents/Resources/ShotloomDistribution.json').read_text())
if (info.get('CFBundleIdentifier') != 'com.monoware.shotloom.direct'
    or info.get('ShotloomDistributionChannel') != 'direct' or metadata.get('channel') != 'direct'
    or metadata.get('version') != info.get('CFBundleShortVersionString')
    or metadata.get('build') != info.get('CFBundleVersion')):
    raise SystemExit('Direct candidate metadata mismatch. No upload started.')
PY
stage="$(mktemp -d "$PWD/build/direct/.notary.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
/usr/bin/ditto "$candidate" "$stage/Shotloom.app"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$stage/Shotloom.app" "$stage/submission.zip"
xcrun notarytool submit "$stage/submission.zip" --keychain-profile "$notary_profile" \
  --wait --timeout 30m --output-format json > "$stage/notarization.json"
python3 - "$stage/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file:
    result = json.load(file)
if result.get('status') != 'Accepted':
    raise SystemExit('Notarization was not accepted. Original candidate remains unchanged.')
PY
xcrun stapler staple "$stage/Shotloom.app"
xcrun stapler validate "$stage/Shotloom.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$stage/Shotloom.app"
rm "$stage/submission.zip"
output="$PWD/build/direct/notarized-$(date -u +%Y%m%dT%H%M%SZ)-${stage:t}"
mv "$stage" "$output"
stage=""
print "Notarized private candidate: $output/Shotloom.app"
print 'Not a commercial release. App quality evidence and payment/activation work remain separate.'
