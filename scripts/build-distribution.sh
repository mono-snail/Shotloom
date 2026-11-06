#!/bin/zsh
# An explicit release job. Never changes user captures/preferences or restarts apps.
set -euo pipefail
cd "${0:A:h:h}"
release_identity="${DESKCAPTURE_SIGN_IDENTITY:-}"
notary_profile="${DESKCAPTURE_NOTARY_PROFILE:-}"
if [[ "$release_identity" != 'Developer ID Application:'* || -z "$notary_profile" ]]; then
  print -u2 -- 'Distribution requires an existing Developer ID Application identity and a configured notarytool keychain profile. No build or upload was started.'
  exit 2
fi
export DESKCAPTURE_SIGN_TIMESTAMP=required
python3 scripts/configure-updates.py Resources/Info.plist --check --require-complete
zsh scripts/build-app.sh release
# Quality diagnostics are only run on an explicit user request. Consume an
# existing report for this exact signed executable; do not launch diagnostics.
python3 scripts/require-current-quality.py "$PWD/build/DeskCapture.app" build/quality-diagnostic.json
notary_stage="$(mktemp -d "$PWD/build/notary-stage.XXXXXX")"
trap 'rm -rf "$notary_stage"' EXIT
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$PWD/build/DeskCapture.app" "$notary_stage/DeskCapture.zip"
xcrun notarytool submit "$notary_stage/DeskCapture.zip" --keychain-profile "$notary_profile" --wait --timeout 30m --output-format json > build/notarization-result.json
python3 - <<'PY'
import json
with open('build/notarization-result.json') as file: report=json.load(file)
if report.get('status') != 'Accepted': raise SystemExit('Notarization was not accepted; no release package was produced.')
PY
xcrun stapler staple "$PWD/build/DeskCapture.app"
xcrun stapler validate "$PWD/build/DeskCapture.app"
/usr/sbin/spctl --assess --type execute --verbose=2 "$PWD/build/DeskCapture.app"
zsh scripts/package-app.sh
