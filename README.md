# Shotloom

Shotloom is a native macOS screenshot, screen recording and local editing application. This repository publishes a source snapshot for inspection. It is not an open-source license grant; see [LICENSE](LICENSE).

## Product

- Region, window and screen capture, with annotation and local history.
- Manual scrolling capture and stitched output.
- Configurable local image workflows, including watermarking, styling, resizing and delivery.
- A manual sensitive-information review checkpoint. OCR, when included in that workflow, runs on the redacted result.
- Screen recording with optional camera, microphone and system audio, plus local editing and export.

Detection and OCR can miss information; users must review results before sharing. Captures are not automatically uploaded. Optional user-initiated support uses MonoWare's support service.

## Source layout

| Path | Responsibility |
| --- | --- |
| `Sources/DeskCapture` | Capture, recording, editing, workflow processing and native UI |
| `Sources/DeskCapture/LocalWorkflow.swift` | Workflow steps, ordering constraints and processing |
| `Sources/DeskCapture/WorkflowSensitiveReview.swift` | Manual review interaction |
| `Sources/DeskCapture/WorkflowTools.swift` | Output configuration and delivery |
| `Resources` | Bundle configuration and app artwork |
| `Tests/DeskCaptureTests` | Host-side tests and synthetic fixtures |
| `scripts` | Build, packaging and development tools |
| `ThirdPartyNotices` | Notices for external processing components |

## Build

The current target is Apple silicon with macOS 15 or later. Use Xcode with Swift 6 tooling. The Swift package's executable/module retains the internal name `DeskCapture`; the product is Shotloom.

For the SwiftPM development executable:

```sh
swift build --product DeskCapture
```

SwiftPM resolves the pinned Sparkle binary dependency. Bundled speech and voice helpers require additional setup using `scripts/build-speech-runtime.sh` and `scripts/build-voice-runtime.sh`; these scripts download pinned upstream sources/data when the cache is absent. Read the scripts before running them. Optional transcription models are not included in this repository and are not needed for basic capture/editing.

For a Mac App Store build, use `Shotloom.xcodeproj`, scheme `Shotloom`, and your own valid signing/provisioning configuration. The generated project can be refreshed using `python3 scripts/generate-store-project.py`. The store helper build phase requires locally prepared voice/speech binaries. `APP_STORE` excludes Sparkle's updater. `DIRECT_DISTRIBUTION` is a separate distribution channel, not a payment or licensing implementation.

The existing Mac App Store product retains `com.deskcapture.mac` so updates remain attached to its existing App Store Connect record. The development bundle ID is `app.monoware.shotloom`. Version 1.0 build 57 includes the current permission-scope changes; it was archived and uploaded on 2026-11-06. Uploading a build does not submit it for review.

## Verification

On 2026-11-06, the preceding source snapshot passed 605 Swift tests and 35 Python tests. Tests were not rerun after the subsequent permission-scope changes. The current build 57 passed signed Release archiving and signature verification and was accepted for processing by App Store Connect. See `VALIDATION.md` for coverage and limitations. These are internal checks, not external beta feedback.

## Dependencies and origin

The product owner reports that no complete ready-made screenshot app project or commercial app template was adopted; GPT assisted with code generation. External libraries are explicitly acknowledged: whisper.cpp/ggml for optional local transcription, RNNoise for voice denoising, libebur128 for loudness measurement, and Sparkle for non-store updates. See `THIRD_PARTY.md` and `ThirdPartyNotices`.

This is a fresh public source snapshot. Internal development history, account records, review correspondence, screenshots of account dashboards, credentials, generated build outputs and the separately maintained website repository are excluded. A source manifest records the files included.

## Rights and contact

The repository is publicly readable for inspection. No additional permission to reuse, distribute or commercially exploit the project's own code or artwork is granted beyond applicable law and GitHub's platform terms. Third-party components remain under their own licenses. Shotloom and MonoWare names and artwork are not licensed as branding for other products.

Website: https://shotloom.monoware.app

Support: support@monoware.app
