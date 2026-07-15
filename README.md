# MoMoWhisper

MoMoWhisper is an open-source meeting recorder and transcription workbench. The macOS app keeps microphone and system-audio transcript routes separate, preserves meeting history, and can produce local or explicitly configured AI summaries. A separate Windows x64 Beta provides local dual-source recording and post-meeting transcription.

> **Release status:** source builds and the unsigned Windows x64 Beta are available publicly. The public macOS installer is intentionally withheld until Developer ID signing and Apple notarization are completed; CI-only unsigned Mac artifacts are not release downloads.

## Platform support

| Platform | Status |
|---|---|
| macOS 26+ | Supported; SpeechAnalyzer is the preferred transcription engine. |
| macOS 14–25 | Supported; the app defaults and safely falls back to Apple Speech. |
| Windows 10 1809+ / 11 x64 | Beta; separate .NET implementation with post-stop local transcription. |

The current package targets macOS 14 or later. SpeechAnalyzer itself requires macOS 26; selecting it on an older system is disabled and recording resolves to Apple Speech. An `arm64` artifact runs only on Apple silicon. A `universal` artifact contains both `arm64` and `x86_64` slices for Apple silicon and Intel Macs; the public notarized release path requires this universal build and fails if either slice cannot be produced.

## Features

- Microphone and system-audio transcription modes; simultaneous separate dual-source transcription requires SpeechAnalyzer on macOS 26 or later.
- Timestamped transcript segments with microphone and system-audio labels.
- Recording-session lifecycle protection and multi-part recording metadata.
- Searchable meeting history, Markdown export, and delivery readiness checks.
- Transcript-only mode by default.
- Local fallback summaries, local LM Studio, DeepSeek, and custom OpenAI-compatible endpoints.
- API key storage in macOS Keychain.

## Install a published macOS release

1. Open this repository's **Releases** page.
2. Download `MoMoWhisper-<version>-macOS-universal-developer-id-notarized.dmg` and its `.sha256` file.
3. Verify the checksum, open the DMG, and drag `MoMoWhisper.app` to Applications.
4. Launch the app and complete the permission onboarding.

Only artifacts labeled `developer-id-notarized` are intended for public distribution and normal Gatekeeper verification. Artifacts labeled `developer-id-unnotarized` are signed but have not passed Apple notarization; artifacts labeled `unsigned` use an ad-hoc signature for CI or local development. Gatekeeper may block either non-notarized form, and neither should be attached to a public GitHub Release.

## Install the Windows Beta

1. Open this repository's **Releases** page.
2. Download `MoMoWhisper-Windows-Beta-<version>-x64-Setup.exe` and `MoMoWhisper-Windows-Beta-SHA256SUMS.txt`.
3. Verify the SHA-256 checksum, then run the per-user installer.
4. Grant microphone access when Windows asks, and run a short microphone/system-audio test before an important meeting.

The Windows build is an explicitly labeled **unsigned Beta**. Until an Authenticode publisher certificate and Windows 10/11 compatibility evidence are available, Microsoft Defender SmartScreen may show an unknown-publisher warning. The Beta records microphone and system playback to separate tracks, then transcribes locally after recording stops; it does not yet match the macOS live-transcription feature set. See [windows/README.md](windows/README.md) for exact limits and data locations.

## Permissions

MoMoWhisper requests only the permissions needed by the selected mode:

- Speech Recognition for Apple transcription.
- Microphone for microphone capture.
- Screen and System Audio Recording for computer playback capture.

After changing Screen and System Audio Recording permission, quit MoMoWhisper completely and reopen it.

## Data and privacy defaults

New macOS installations store meeting data locally at:

```text
~/Library/Application Support/MoMoWhisper/
```

The app does not silently move data to iCloud. You may explicitly choose a synced folder for recordings or highlights in Settings.

The Windows Beta stores its meeting data locally under `%LOCALAPPDATA%\MoMoWhisper\WindowsBeta\` and does not upload transcripts or audio. See [PRIVACY.md](PRIVACY.md) for retention and encryption boundaries on both platforms.

New installations default to **transcript only**. Local automatic summaries do not contact a third party. Transcript text is sent over the network only after you explicitly select and configure DeepSeek, LM Studio, or another OpenAI-compatible endpoint. Apple Speech may use Apple-operated services depending on macOS, language, and system availability.

Read [PRIVACY.md](PRIVACY.md) before recording sensitive meetings or enabling a remote summary provider.

## Build from source

Requirements:

- macOS 14 or later.
- Swift 6 toolchain from a current Xcode or Command Line Tools installation.

Build and run the deterministic regression runner:

```bash
TMPDIR=/tmp swift build -j 4 --scratch-path /tmp/momowhisper-build
TMPDIR=/tmp swift run -j 4 --scratch-path /tmp/momowhisper-runner MoMoWhisperLifecycleTestRunner
```

Create a local ad-hoc app bundle and DMG:

```bash
MOMO_WHISPER_OUTPUT_DIR=/tmp/momowhisper-dist \
  bash scripts/package-macos.sh
```

Verify an ad-hoc artifact structurally:

```bash
bash scripts/verify-macos-release.sh --allow-adhoc \
  /tmp/momowhisper-dist/MoMoWhisper-0.1.0-macOS-arm64-unsigned.dmg
```

Ad-hoc output is for local development only. A Developer ID build without a notary profile is clearly labeled `developer-id-unnotarized` and is also not public-ready. Public packaging requires a Developer ID Application identity, Apple notarization, and `--universal`; the script writes `developer-id-notarized` and `PublicDistributionReady: yes` only after both the app and DMG pass notarization and stapling. See `scripts/package-macos.sh --help`.

## First use

1. Choose Apple Speech or SpeechAnalyzer when available.
2. Choose an audio mode and microphone.
3. Run the pre-meeting health check and system-audio test when applicable.
4. Start recording and confirm that audio levels and transcript segments update.
5. Open Delivery Center after stopping to review transcript, summary, recording-part, and handoff readiness.

## Summary providers

- **Transcript only**: default; no summary endpoint is contacted.
- **Local automatic summary**: local fallback only.
- **LM Studio**: requires an endpoint explicitly entered in Settings; localhost is recommended for local use.
- **DeepSeek / other OpenAI-compatible API**: requires an endpoint, model, and API key explicitly saved in Settings.

MoMoWhisper does not load API tokens from environment variables, Downloads, or legacy handoff files.

## Development checks

```bash
TMPDIR=/tmp swift test -j 4 --scratch-path /tmp/momowhisper-tests
TMPDIR=/tmp swift run -j 4 --scratch-path /tmp/momowhisper-runner MoMoWhisperLifecycleTestRunner
```

See [SECURITY.md](SECURITY.md) for vulnerability reporting and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency boundaries.

## License

MoMoWhisper is available under the MIT License. See [LICENSE](LICENSE).
