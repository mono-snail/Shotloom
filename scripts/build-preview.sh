#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
preview_optimization="-O"
preview_name="DeskCaptureInteractionPreview"
preview_source="scripts/InteractionPreview.swift"
preview_id="com.deskcapture.interaction-preview"
if [[ "${1:-}" == '--scroll' ]]; then
  preview_name="DeskCaptureScrollPreview"
  preview_source="scripts/ScrollPreviewFixture.swift"
  preview_id="com.deskcapture.scroll-preview"
fi
if [[ "${1:-}" == '--interface' ]]; then
  preview_optimization="-Onone"
  preview_name="DeskCaptureInterfacePreview"
  preview_source="scripts/InterfacePreview.swift"
  preview_id="com.deskcapture.interface-preview"
fi
if [[ "${1:-}" == '--text' ]]; then
  preview_optimization="-Onone"
  preview_name="DeskCaptureTextEditorPreview"
  preview_source="scripts/TextEditorPreview.swift"
  preview_id="com.deskcapture.text-editor-preview"
fi
if [[ "${1:-}" == '--video' ]]; then
  preview_optimization="-Onone"
  preview_name="DeskCaptureVideoEditorPreview"
  preview_source="scripts/VideoEditorPreview.swift"
  preview_id="com.deskcapture.video-editor-preview"
fi
if [[ "${1:-}" == '--local-image' ]]; then
  preview_optimization="-Onone"
  preview_name="DeskCaptureLocalImagePreview"
  preview_source="scripts/LocalImagePreview.swift"
  preview_id="com.deskcapture.local-image-preview"
fi
preview_dir="$PWD/build/$preview_name.app"
mkdir -p "$preview_dir/Contents/MacOS"
sources=(Sources/DeskCapture/*.swift)
sources=(${sources:#*/main.swift})
swiftc "$preview_optimization" -swift-version 5 -parse-as-library -o "$preview_dir/Contents/MacOS/$preview_name" "$sources[@]" "$preview_source"
cat > "$preview_dir/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$preview_id</string>
<key>CFBundleName</key><string>$preview_name</string>
<key>CFBundleExecutable</key><string>$preview_name</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$preview_dir"
