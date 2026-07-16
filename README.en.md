# MoMoWhisper

<p align="center">
  <a href="README.md">繁體中文</a> · <strong>English</strong>
</p>

MoMoWhisper is an open-source meeting recorder and transcription workbench. The macOS app keeps microphone and system-audio transcript routes separate, preserves meeting history, and can produce local or explicitly configured AI summaries. A separate Windows x64 Beta provides local dual-source recording and post-meeting transcription.

> **Release status:** source builds, the unsigned Windows x64 Beta, and an ad-hoc-signed macOS universal Beta are available publicly. Neither installer Beta has a trusted publisher signature. The macOS Beta is not Apple-notarized and requires a manual Gatekeeper exception.

## Platform support

| Platform | Status |
|---|---|
| macOS 26+ | Beta; SpeechAnalyzer is the preferred transcription engine. |
| macOS 14–25 | Beta; the app defaults and safely falls back to Apple Speech. |
| Windows 10 1809+ / 11 x64 | Beta; separate .NET implementation with post-stop local transcription. |

The current package targets macOS 14 or later. SpeechAnalyzer itself requires macOS 26; selecting it on an older system is disabled and recording resolves to Apple Speech. An `arm64` artifact runs only on Apple silicon. A `universal` artifact contains both `arm64` and `x86_64` slices for Apple silicon and Intel Macs; the public notarized release path requires this universal build and fails if either slice cannot be produced.

## Features

- Microphone and system-audio transcription modes; simultaneous separate dual-source transcription requires SpeechAnalyzer on macOS 26 or later.
- Timestamped transcript segments with microphone and system-audio labels.
- Recording-session lifecycle protection and multi-part recording metadata.
- Searchable meeting history, Markdown export, and delivery-readiness checks.
- Summary V2 reading mode with a headline, topic groups, decision/requirement/action/open-question/risk types, search and filters, plus source and processing coverage.
- Long topics show the eight highest-priority items by default, while Copy Full Summary exposes the complete audit. For a committed meeting, the authoritative summary is `session_state_v1.json#/snapshot/summaryDocument`; `summary_document.json` and the default Markdown are mutable compatibility previews for legacy tools and reading convenience, not substitutes for the authoritative snapshot.
- User-edited locked items survive later AI updates; transcript changes invalidate stale generated coverage and trigger recomputation.
- A short meeting can update the `latest_valid` handoff only when its transcript reaches 300 characters or its summary contains manual or user-locked content. AI-only and fallback-only summaries cannot replace the previous trusted handoff.
- The macOS Codex handoff schema v2 binds a handoff to one `session_state_v1.json` commit through `sessionTransactionID` and `sessionStatePath`. Readiness re-reads the authoritative envelope and checks its transaction ID, meeting ID, schema, path boundary, and snapshot structure. Missing, stale, mismatched, path-escaping, or undecodable evidence fails closed; this is not a cryptographic anti-tamper signature. Compatibility-preview paths remain untrusted. The Windows Beta uses a separate handoff schema without this macOS transaction trust chain.
- Meeting history uses a lightweight `history_index_v1.json` written only after the authoritative snapshot commit plus an in-memory cache; autosave does not re-decode every long meeting merely to refresh the list.
- Routine autosaves use a 250 ms debounce and same-session latest-wins coalescing through one serialized background writer; an already-started commit is never cancelled midway. Stop, clear/session-switch, and final-export boundaries use a zero-delay flush so growing transcripts are not synchronously serialized on UI or ASR callbacks.
- Manual edits to an ended meeting republish final highlights and handoff artifacts so `latest_valid` stays bound to the newest authoritative transaction. Next Meeting switches only after the authoritative snapshot and required artifacts succeed, and Clear is unavailable while recording.
- Cmd-Q delays AppKit termination until the newest revision and final artifacts are durable. If persistence or artifact export fails, quitting is cancelled and the current meeting remains available for retry.
- Transcript-only mode by default.
- Local fallback summaries, local LM Studio, DeepSeek, and custom OpenAI-compatible endpoints.
- API key storage in macOS Keychain.

## Install the macOS unsigned Beta

1. Open this repository's [**Releases**](https://github.com/jordannn02/MoMoWhisper/releases) page.
2. Download `MoMoWhisper-0.2.0-macOS-universal-unsigned.dmg` and `MoMoWhisper-0.2.0-macOS-universal-unsigned.sha256`. The ZIP is an alternative copy of the same universal app.
3. Verify the DMG checksum:

   ```bash
   cd ~/Downloads
   grep 'MoMoWhisper-0.2.0-macOS-universal-unsigned.dmg$' \
     MoMoWhisper-0.2.0-macOS-universal-unsigned.sha256 |
     shasum -a 256 -c -
   ```

4. Open the DMG and drag `MoMoWhisper.app` to Applications.
5. Try to open the app once. Gatekeeper is expected to reject this ad-hoc-signed, non-notarized Beta.
6. If you trust the checksum and this repository, open **System Settings → Privacy & Security**, scroll to Security, and choose **Open Anyway** for MoMoWhisper. Apple documents this per-app override [here](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac).
7. Launch the app and complete the permission onboarding.

The `unsigned` filename is intentional: the app has only an ad-hoc structural signature, no Apple Developer Team identity, no notarization ticket, and no Apple malware-screening result. The checksum detects a mismatched download; it does not establish publisher identity or software safety. Do not disable Gatekeeper globally, run a copy from another source, or bypass a warning that says the app will damage your Mac or contains malware. A future artifact labeled `developer-id-notarized` will be the normal-distribution build and will not require this manual exception.

## Install the Windows Beta

1. Open this repository's [**Releases**](https://github.com/jordannn02/MoMoWhisper/releases) page.
2. Download `MoMoWhisper-Windows-Beta-<version>-x64-Setup.exe` and `MoMoWhisper-Windows-Beta-SHA256SUMS.txt`.
3. Verify the SHA-256 checksum, then run the per-user installer.
4. Grant microphone access when Windows asks, and run a short microphone/system-audio test before an important meeting.

The Windows build is an explicitly labeled **unsigned Beta**. Until an Authenticode publisher certificate and Windows 10/11 compatibility evidence are available, Microsoft Defender SmartScreen may show an unknown-publisher warning. The Beta records microphone and system playback to separate tracks, then transcribes locally after recording stops; it does not yet match the macOS live-transcription feature set. See [windows/README.md](windows/README.md) for exact limits and data locations.

The Windows `momowhisper.windows-beta.v2` handoff is a separate format and does not contain the macOS `sessionTransactionID`/`sessionStatePath` verification chain. Do not apply macOS Summary V2 trust claims to the Windows Beta.

The Windows installer is produced by GitHub-hosted Windows CI and is attached to a GitHub Release only after the tag workflow completes its core tests, static whisper runtime checks, silent installation, executable launch, and uninstall smoke test. A local macOS build/test is not evidence that the Windows installer passed these checks.

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
  /tmp/momowhisper-dist/MoMoWhisper-0.2.0-macOS-arm64-unsigned.dmg
```

Ad-hoc output is not public-ready by default and remains marked `PublicDistributionReady: no`. The 0.2.0 Beta is a manually approved, explicitly labeled unsigned exception; automation only creates structurally verified CI artifacts and does not automatically attach an ad-hoc Mac build to a Release. A Developer ID build without a notary profile is labeled `developer-id-unnotarized` and is also not normal-distribution ready. Normal public packaging requires a Developer ID Application identity, Apple notarization, and `--universal`; the script writes `developer-id-notarized` and `PublicDistributionReady: yes` only after both the app and DMG pass notarization and stapling. See `scripts/package-macos.sh --help`.

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

A remote summary request contains only committed transcript excerpts, recent text context, and the existing catalog fields needed for continuity: headline; topic ID/title/aliases; and item ID/topic/type/status/text/owner/due-date/manual-lock state. Raw audio is not sent. If a provider fails, local fallback preserves every failed range and the UI reports AI, local fallback, pending, and retry coverage separately.

MoMoWhisper does not load API tokens from environment variables, Downloads, or legacy handoff files.

## Development checks

```bash
TMPDIR=/tmp swift test -j 4 --scratch-path /tmp/momowhisper-tests
TMPDIR=/tmp swift run -j 4 --scratch-path /tmp/momowhisper-runner MoMoWhisperLifecycleTestRunner
bash scripts/run-summary-v2-smoke-tests.sh
```

See [SECURITY.md](SECURITY.md) for vulnerability reporting and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependency boundaries.

## License

MoMoWhisper is available under the MIT License. See [LICENSE](LICENSE).
