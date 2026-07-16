# MoMoWhisper 0.1.0 Beta

This is the first public source release of MoMoWhisper.

## Windows x64 Beta

- Separate microphone and system-playback recording through WASAPI.
- Local post-stop transcription with a pinned, statically built whisper.cpp CLI and multilingual base model.
- `[MIC]` / `[SYS]` transcript labels, per-session metadata, local highlights, history, and Codex handoff artifacts.
- Fail-closed handoff policy: empty, incomplete, cancelled, or failed transcription attempts do not replace `latest_valid`.
- Per-user Inno Setup installer for Windows 10 1809+ and Windows 11 x64.

The Windows package is an **unsigned Beta**. Verify its published SHA-256 checksum. Microsoft Defender SmartScreen may show an unknown-publisher warning. CI verifies build, core tests, runtime dependencies, silent installation, executable smoke mode, and uninstallation; real audio devices, Defender/SmartScreen reputation, mixed-language meetings, and long-meeting performance still require broader field verification.

## macOS

This prerelease now includes a manually approved **unsigned macOS Beta** for macOS 14 or later:

- `MoMoWhisper-0.1.0-macOS-universal-unsigned.dmg` — SHA-256 `1f22d8d85cddd4065b53a0c8f7a2d4ec7f5313add9f10a506b4c1a6fd41e19ba`
- `MoMoWhisper-0.1.0-macOS-universal-unsigned.zip` — SHA-256 `aedb1e2bbef6318c92b7b1fe46fcc88b1d36c7720dffdcc58a57442851462e4e`
- Universal binary with `x86_64` and `arm64` slices.
- Version `0.1.0`, build `1`, bundle ID `com.jordannn02.MoMoWhisper`.

The app has an ad-hoc hardened-runtime signature and the audio-input entitlement, but it has **no Developer ID identity, no Apple notarization, and no stapled ticket**. Gatekeeper is expected to reject it. After trying to launch once, users who have verified the checksum and trust this repository can use **System Settings → Privacy & Security → Open Anyway** as documented by [Apple Support](https://support.apple.com/guide/mac-help/open-an-app-by-overriding-security-settings-mh40617/mac). The checksum confirms matching bytes; it is not a substitute for publisher identity, notarization, or malware review. Do not disable Gatekeeper globally or bypass a warning that says the app will damage your Mac or contains malware.

GitHub Actions run `29405831384` executed 14 Swift tests, the lifecycle regression runner, universal packaging, and DMG/ZIP structural verification successfully. The release was also rechecked locally: both checksums passed, `codesign --verify --deep --strict` passed structural validation, while `spctl` rejected the app and `stapler` confirmed that no ticket exists. Real third-party Macs, fresh permission onboarding, and the manual Gatekeeper override remain Beta field-verification boundaries.

A future normal-distribution Mac download will use Developer ID signing, Apple notarization, stapling, Gatekeeper verification, and checksum verification. This Beta remains `PublicDistributionReady: no`. The automated workflow continues to withhold ad-hoc artifacts; this v0.1.0 attachment is an explicit manual Beta exception.

## Privacy defaults

- macOS starts in transcript-only mode and does not silently move data to iCloud.
- Windows transcription is local and the Beta has no remote summary provider.
- Meeting files remain on disk until the user deletes them; uninstalling the app does not delete meeting data.

See `README.md`, `PRIVACY.md`, `SECURITY.md`, and the platform-specific third-party notices before use.
