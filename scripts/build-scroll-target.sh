#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
fixture_app="$PWD/build/ScrollFixtureTarget.app"
mkdir -p "$fixture_app/Contents/MacOS"
swiftc -O -swift-version 5 scripts/ScrollFixtureTarget.swift -o "$fixture_app/Contents/MacOS/ScrollFixtureTarget"
cat > "$fixture_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.deskcapture.scroll-fixture-target</string>
<key>CFBundleName</key><string>ScrollFixtureTarget</string>
<key>CFBundleExecutable</key><string>ScrollFixtureTarget</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$fixture_app"
