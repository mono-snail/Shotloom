#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
app_path="$PWD/build/DeskCapture.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")
build_number=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$app_path/Contents/Info.plist")
# Version names are used in paths; reject arbitrary bundle text before creating files.
if [[ "$version" != <->.<->.<-> || "$build_number" != <-> ]]; then
  print -u2 -- 'Numeric release version and build are required.'; exit 2
fi
python3 scripts/require-current-quality.py "$app_path" build/quality-diagnostic.json
release_dir="$PWD/releases"; mkdir -p "$release_dir"
release_group="$release_dir/DeskCapture-$version-build$build_number"
[[ ! -e "$release_group" && ! -L "$release_group" ]] || { print -u2 -- "Release folder already exists: $release_group"; exit 2; }
package_stage=$(mktemp -d "$release_dir/.package-stage.XXXXXX")
trap 'rm -rf "$package_stage"' EXIT
mkdir "$package_stage/volume" "$package_stage/output"
ditto "$app_path" "$package_stage/volume/DeskCapture.app"
python3 scripts/require-current-quality.py "$package_stage/volume/DeskCapture.app" build/quality-diagnostic.json
python3 scripts/audit-app-compatibility.py "$package_stage/volume/DeskCapture.app" --output "$package_stage/output/compatibility-audit.json" > "$package_stage/audit.log"
package_arch=$(python3 - "$package_stage/output/compatibility-audit.json" <<'PY'
import json, sys
with open(sys.argv[1]) as file: report=json.load(file)
arches=sorted({item['architecture'] for item in report['binaries'][0]['slices']})
print(arches[0] if len(arches)==1 else 'universal')
PY
)
ln -s /Applications "$package_stage/volume/Applications"
cp "$release_dir/试用说明.txt" "$package_stage/volume/先读我.txt"
hdiutil create -volname "DeskCapture $version" -srcfolder "$package_stage/volume" -format UDZO "$package_stage/output/DeskCapture-$version-$package_arch.dmg"
ditto -c -k --sequesterRsrc --keepParent "$package_stage/volume/DeskCapture.app" "$package_stage/output/DeskCapture-$version-$package_arch.zip"
cp build/quality-diagnostic.json "$package_stage/output/quality-diagnostic.json"
python3 scripts/require-current-quality.py "$package_stage/volume/DeskCapture.app" build/quality-diagnostic.json
python3 scripts/commit-new-directory.py "$package_stage/output" "$release_group"
print "Package: $release_group/DeskCapture-$version-$package_arch.dmg"
