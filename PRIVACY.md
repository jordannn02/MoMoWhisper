# MoMoWhisper Privacy

MoMoWhisper records and transcribes meetings. Audio and transcripts can contain sensitive personal or business information, so the app is designed to keep storage and network choices visible.

## Local data

On a new macOS installation, MoMoWhisper stores its data under:

```text
~/Library/Application Support/MoMoWhisper/
```

This includes meeting metadata, transcripts, recordings, highlights, diagnostics, and optional Codex handoff files. MoMoWhisper does not silently migrate these files to iCloud.

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
- **DeepSeek** sends transcript excerpts, recent context, and current summary state to the DeepSeek-compatible endpoint only after you select DeepSeek and save its settings.
- **Other OpenAI-compatible API** sends the same class of meeting text to the endpoint you configure only after you select that provider.
- **LM Studio** sends meeting text to the endpoint you configure only after you select LM Studio. A localhost endpoint normally remains on the same computer; a remote URL sends data to that remote operator.

MoMoWhisper does not scan Downloads, environment variables, or legacy handoff files for API tokens. API keys entered in the app are stored in macOS Keychain. Review the privacy and retention terms of every endpoint you configure.

## Telemetry

MoMoWhisper does not include first-party analytics, advertising, crash-reporting SDKs, or telemetry upload code. Local diagnostics record capture and permission status to help troubleshoot audio issues.

## Retention and deletion

Files remain until you delete them. Removing either app does not automatically delete meeting files; removing the macOS app also does not automatically delete Keychain entries. Windows Beta recordings and transcripts are not encrypted by the app, so use operating-system disk encryption and normal account protections when required. Before sharing diagnostics or opening a public issue, remove meeting titles, transcripts, paths, tokens, and other private information.

## Recording consent

You are responsible for obtaining any consent required to record or transcribe other people and for complying with applicable workplace rules and laws.
