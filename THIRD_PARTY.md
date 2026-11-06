# Third party components

These libraries provide specific processing or update functions. They do not provide a complete Shotloom application template. Their upstream names and notices are retained.

| Component | Role | Declaration |
| --- | --- | --- |
| [whisper.cpp and ggml](https://github.com/ggml-org/whisper.cpp) | Optional local speech transcription | `scripts/build-speech-runtime.sh`, pinned revision `d1be6fde11ac6e0407606b4e42fe72d34add8037` |
| [RNNoise](https://github.com/xiph/rnnoise) | Voice denoising | `scripts/build-voice-runtime.sh`, version 0.2 |
| [libebur128](https://github.com/jiixyj/libebur128) | Loudness measurement | `scripts/build-voice-runtime.sh`, version 1.2.6 |
| miniaudio and stb_vorbis | Supporting sources/notices distributed in the pinned whisper.cpp tree; exact linked reachability not asserted | `scripts/build-speech-runtime.sh` |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Developer/direct-distribution updates only | `Package.swift`, version 2.10.0; excluded by `APP_STORE` |

Notices in `ThirdPartyNotices` are copied from the locally prepared upstream artifacts. Build scripts also embed the relevant notices alongside the bundled helpers. Model files, compiled third-party executables and third-party source archives are not republished in this snapshot. Optional models have their own source/licensing information; no license for model weights is inferred from a runtime library's license.

Apple frameworks such as AppKit, SwiftUI, ScreenCaptureKit, AVFoundation, Vision and App Intents are platform frameworks. The project's own source-availability notice does not relicense third-party or platform materials.
