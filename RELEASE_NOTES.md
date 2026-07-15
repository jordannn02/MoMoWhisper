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

The public repository includes the macOS 14+ Swift source and reproducible universal packaging scripts. CI-only unsigned artifacts are not attached to public Releases. A normal public Mac download will be added only after Developer ID signing, Apple notarization, stapling, Gatekeeper verification, and checksum verification all succeed.

## Privacy defaults

- macOS starts in transcript-only mode and does not silently move data to iCloud.
- Windows transcription is local and the Beta has no remote summary provider.
- Meeting files remain on disk until the user deletes them; uninstalling the app does not delete meeting data.

See `README.md`, `PRIVACY.md`, `SECURITY.md`, and the platform-specific third-party notices before use.
