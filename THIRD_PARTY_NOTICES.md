# Third-Party Notices

MoMoWhisper is distributed under the MIT License. See `LICENSE`.

## Runtime frameworks

The app uses frameworks supplied by macOS, including SwiftUI, AppKit, AVFoundation, Speech, ScreenCaptureKit, CoreAudio, CoreMedia, CoreGraphics, Security, and Foundation. These frameworks are provided by Apple as part of macOS and the Apple developer toolchain and remain subject to Apple's applicable terms.

The current `Package.swift` declares no third-party Swift Package Manager dependencies.

## Windows Beta

The separate Windows Beta redistributes pinned builds of NAudio, whisper.cpp, and a multilingual whisper.cpp model. Its dependency versions, licenses, source links, and redistribution boundary are documented in `windows/THIRD_PARTY_NOTICES.md`. The Windows packaging workflow copies only the runtime files required by `whisper-cli`; unrelated executables from the upstream release archive are not included.

## Optional services

MoMoWhisper can connect to user-configured services such as DeepSeek, LM Studio, or another OpenAI-compatible endpoint. These services and models are not bundled with MoMoWhisper. Their software, model, API, trademark, billing, and data-use terms are controlled by their respective providers.

Apple, macOS, SwiftUI, AppKit, SpeechAnalyzer, and other Apple product names are trademarks of Apple Inc. DeepSeek, LM Studio, OpenAI, and model names belong to their respective owners. Their mention does not imply endorsement.

## Build-only GitHub Actions

The GitHub workflow references official marketplace actions for checkout and artifact transfer. They run in CI and are not included in the installed application. Refer to each action's repository for its license and terms.

Update this file whenever a third-party library, model, binary, font, or other redistributable asset is added.
