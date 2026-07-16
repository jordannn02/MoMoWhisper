# MoMoWhisper Privacy

MoMoWhisper records and transcribes meetings. Audio and transcripts can contain sensitive personal or business information, so the app is designed to keep storage and network choices visible.

## Local data

On a new macOS installation, MoMoWhisper stores its data under:

```text
~/Library/Application Support/MoMoWhisper/
```

This includes meeting metadata, transcripts, recordings, highlights, diagnostics, and optional Codex handoff files. MoMoWhisper does not silently migrate these files to iCloud.

For a committed macOS meeting, the complete source of truth is the local `session_state_v1.json` envelope. The authoritative structured summary is at `#/snapshot/summaryDocument`, and the authoritative transcript and metadata are in the same snapshot. Files such as `summary_document.json`, `transcript.md`, `metadata.json`, and `highlights.md` are mutable compatibility previews for legacy tools and convenient reading; they can be replaced by a later save and must not be treated as an independently committed version.

The Windows Beta stores its local data separately under:

```text
%LOCALAPPDATA%\MoMoWhisper\WindowsBeta\
```

Its bundled whisper.cpp engine and model perform post-meeting transcription locally. The Windows Beta has no remote summary-provider or telemetry integration.

The macOS settings screen lets you choose other folders for recordings and highlights. If you choose iCloud Drive, Dropbox, OneDrive, a network volume, or another synced location, that provider may upload the files under its own terms and privacy policy.

## Permissions

Depending on the selected capture mode, macOS may ask for:

- Microphone access, for microphone recording and transcription.
- Speech recognition access, for Apple speech recognition.
- Screen and system audio recording access, for capturing computer playback.

MoMoWhisper does not use macOS Dictation to type text into other applications.

On Windows, the Beta uses the microphone and the selected/default render endpoint for WASAPI loopback capture. Windows privacy controls, audio drivers, and conferencing applications can independently affect whether those sources are available. Run a short test before recording a sensitive or important meeting.

## Speech recognition

- On macOS 26 or later, MoMoWhisper can use Apple SpeechAnalyzer. Required language assets may be downloaded by macOS.
- On macOS 14 and 15 through 25, MoMoWhisper defaults to Apple Speech. Depending on the language, system configuration, and Apple service availability, recognition may run on-device or use Apple-operated services. MoMoWhisper does not claim that this path is always offline.

Apple controls its speech service and operating-system privacy behavior.

The Windows Beta uses the bundled whisper.cpp executable and multilingual model after recording stops. That transcription path is local and does not use Apple Speech or a remote speech API.

## Meeting summaries and network transfer

New macOS installations default to **transcript only**, with summary transmission disabled. The Windows Beta has no remote summary-provider feature.

- **Local automatic summary** uses MoMoWhisper's local fallback and does not contact a third-party summary endpoint.
- **DeepSeek** sends committed transcript excerpts, recent text context, and the existing summary catalog fields needed for continuity: headline; topic ID, title, and aliases; and item ID, topic ID, type, status, text, owner, due date, and manual-lock state. This happens only after you select DeepSeek and save its settings.
- **Other OpenAI-compatible API** sends the same class of meeting text and summary catalog fields to the endpoint you configure only after you select that provider.
- **LM Studio** sends meeting text to the endpoint you configure only after you select LM Studio. A localhost endpoint normally remains on the same computer; a remote URL sends data to that remote operator.

MoMoWhisper does not scan Downloads, environment variables, or legacy handoff files for API tokens. API keys entered in the app are stored in macOS Keychain. Review the privacy and retention terms of every endpoint you configure.

Summary-provider requests do not include raw meeting audio. Cancelling or switching a meeting cancels pending retry work; the app validates persisted retry ranges against the current committed transcript before any retry request is sent.

## macOS session persistence and handoff consistency

Routine macOS autosaves are coalesced for 250 milliseconds with same-session latest-wins behavior and are written by one serialized background writer. A write that has already started is allowed to finish, while stop, clear/session-switch, and final-export boundaries use a zero-delay flush. This changes when local files are committed; it does not add a network destination or telemetry.

The macOS Codex handoff schema v2 contains `sessionTransactionID` and `sessionStatePath`. The app treats a handoff as ready only after reading the referenced `session_state_v1.json` and checking its transaction ID, meeting ID, schema, path boundary, and decodable snapshot structure. Missing, stale, mismatched, path-escaping, or structurally invalid evidence fails closed. This consistency check is not a cryptographic signature or MAC and does not claim to detect a deliberate rewrite of both the envelope and its references. Compatibility-preview paths in the handoff remain untrusted pointers. The Windows Beta uses the separate `momowhisper.windows-beta.v2` handoff format and does not implement this macOS transaction chain.

Handoff files can expose meeting titles, local absolute paths, recording status, and summary-processing metadata even when they do not embed the full transcript. Treat them as meeting data, and redact or remove them before sharing diagnostics or filing a public issue.

## Telemetry

MoMoWhisper does not include first-party analytics, advertising, crash-reporting SDKs, or telemetry upload code. Local diagnostics record capture and permission status to help troubleshoot audio issues.

## Retention and deletion

Files remain until you delete them. Removing either app does not automatically delete meeting files; removing the macOS app also does not automatically delete Keychain entries. On both macOS and Windows, recordings, transcripts, JSON, and Markdown meeting artifacts are not encrypted by MoMoWhisper itself. Use FileVault or BitLocker, normal account protections, and the security controls of any selected sync destination when required. Before sharing diagnostics or opening a public issue, remove meeting titles, transcripts, paths, tokens, and other private information.

## Recording consent

You are responsible for obtaining any consent required to record or transcribe other people and for complying with applicable workplace rules and laws.
