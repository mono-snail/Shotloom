# Validation on 2026-11-06

## Current build: 1.0 (57)

- Screen access is checked at screen-capture entry points. Local editing, workflow configuration, settings and support no longer require screen access; startup no longer captures screen pixels to verify access. The recovery window can be dismissed.
- Signed Mac App Store Release archive: succeeded for Apple silicon, macOS 15 or later. Existing store identity: `com.deskcapture.mac`; development identity: `app.monoware.shotloom`.
- `codesign --verify --deep --strict`: passed.
- App Store Connect upload: succeeded on 2026-11-06; Apple accepted the package for processing. The web build list did not load, so processing completion and build selection were not confirmed. No review submission was made.
- Upload warnings: dSYMs were missing for ShotloomRelaunch, whisper-cli and desk-voice, limiting symbolication of those helpers. The application upload succeeded.
- Current Debug app was opened with isolated preferences and a temporary data directory. The main panel and settings displayed. Screen access was already available on the host, so a fully denied-permission scenario was not exercised.
- Automated tests and full hardware diagnostics were not rerun after the latest permission changes, per the owner's instructions. No simulator or model download was used.

## Earlier snapshot checks

Before the permission-scope changes, the source passed 605 Swift XCTest cases and 35 Python tests, using cached dependencies. An unsigned generic macOS APP_STORE Debug build also succeeded after regenerating a project that had omitted AppDistribution.swift. These prior checks are not test results for build 57.

No current full signed-app recording/camera hardware diagnostic was completed. Signed installation, every permission scenario, notarization, payment and licensing are not established by these results. Internal developer testing is not external beta testing. The public source is not an assertion that every historical submitted binary matches the current tree.
