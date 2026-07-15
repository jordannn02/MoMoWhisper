# MoMoWhisper Windows Beta

This is an intentionally separate Windows sibling for MoMoWhisper. It does not
claim feature parity with the existing macOS SwiftUI application.

## Honest beta boundary

- Windows 10 1809+ / Windows 11, x64 only.
- Records microphone and WASAPI loopback into separate files.
- The Beta currently records the Windows default microphone and default render
  device through WASAPI shared mode; audio-device selection is not implemented
  yet. Raw capture uses each endpoint's native/mix format, and `metadata.json`
  records its endpoint ID, friendly name, and capture format.
- Transcription starts only after Stop. There is no live transcription.
- Post-stop normalization/transcription can be cancelled. Audio is finalized
  first; metadata then records `postStopProcessingStatus=cancelled` and the
  cancellation timestamp.
- Each new meeting receives a unique session directory and unique recording
  part paths. Writers use `FileMode.CreateNew` and refuse overwrites.
- Both sources are normalized to 16 kHz, 16-bit, mono PCM before whisper.cpp.
- Bundled whisper.cpp runs locally with the multilingual `ggml-base.bin` model.
- A valid whisper JSON document must contain the `transcription` array. A valid
  zero-segment result is marked `no-speech`, emits a warning, and cannot replace
  the last valid handoff.
- Transcript lines retain `[MIC]` and `[SYS]` source labels.
- Cross-source ordering uses each independent WAV's relative whisper timestamp;
  sub-second MIC/SYS start skew is not calibrated in this Beta.
- `highlights.md` is a conservative local excerpt, not an AI semantic summary.
- The Windows Beta currently has no API-provider settings, Apple Speech,
  macOS ScreenCaptureKit behavior, live summary coverage, updater, or signed
  publisher identity.

## Runtime data

The application writes only under:

```text
%LOCALAPPDATA%\MoMoWhisper\WindowsBeta\
  Meetings\<timestamp>_<title>_<session-id>\
    metadata.json
    transcript.md
    highlights.md
    codex_handoff.json
    codex_handoff.md
    recordings\part-001-mic.wav
    recordings\part-001-sys.wav
  CodexHandoff\latest_attempt_handoff.json
  CodexHandoff\latest_attempt_handoff.md
  CodexHandoff\latest_valid_handoff.json
  CodexHandoff\latest_valid_handoff.md
```

Temporary `*.capture.wav` files are retained only when normalization fails so
the original audio can be recovered. That condition is recorded in
`metadata.json.warnings`.

Successful whisper runs delete their temporary `*.whisper-*.json`. Failed or
cancelled runs retain any diagnostic JSON that was produced and record its
location in `metadata.json.warnings`.

`latest_attempt` always describes the most recent processing attempt.
`latest_valid` is updated only when the transcript is non-empty and every audio
source requested for every recording part has completed transcription. Failed,
cancelled, missing-audio, and no-speech attempts preserve the prior
`latest_valid` files.

## Build on Windows

Prerequisites: .NET 8 SDK. The release workflow pins SDK `8.0.423`; its
self-contained installer includes the resolved .NET runtime, so end users do
not install .NET separately. Audio capture and the installer must be tested on
a real Windows machine or Windows VM with usable audio devices.

```powershell
dotnet restore windows\MoMoWhisper.Windows.sln
dotnet test windows\tests\MoMoWhisper.Windows.Core.Tests\MoMoWhisper.Windows.Core.Tests.csproj -c Release
dotnet publish windows\src\MoMoWhisper.Windows\MoMoWhisper.Windows.csproj `
  -c Release -r win-x64 --self-contained true `
  -o windows\artifacts\publish
```

A normal local publish does not contain whisper.cpp or the model. The GitHub
workflow downloads a SHA-256-pinned whisper.cpp v1.9.1 source snapshot, builds a
static `whisper-cli.exe`, verifies with `dumpbin` that it has no whisper/ggml or
MSVC runtime DLL imports, and packages only that executable plus the
SHA-256-pinned model. No separate Visual C++ Redistributable installer is
bundled.

The installer is built with Inno Setup 6.7.1. Inno is a build-time tool; its
compiler is not shipped as an application dependency. See
`THIRD_PARTY_NOTICES.md` for the .NET, NAudio, whisper/model, and Inno license
inventory. The installer also carries the root project as `LICENSE.txt`. The
current installer wizard uses Inno Setup's built-in English messages; the
application interface and generated artifacts remain Traditional Chinese.

## CI release behavior

`.github/workflows/windows-release.yml` runs tests, produces a self-contained
versioned publish, builds and launch-smokes the static whisper.cpp CLI, builds
the installer, performs a silent install / installed-executable smoke / silent
uninstall, and uploads the installer as a workflow artifact. Pull requests and
pushes to `main` run the same build gates; only a `v*` tag can enter the release
upload step.

Pushes to `main` build and retain a workflow artifact. A tag matching `v*`
uploads the installer plus `MoMoWhisper-Windows-Beta-SHA256SUMS.txt` to that
tag's existing release, or creates a prerelease when none exists. Existing
assets are never overwritten. The macOS workflow uploads CI-only artifacts and
does not attach unsigned Mac builds to a public Release. Merely committing the
workflow does not publish a GitHub Release.

## Required release verification

The following cannot be proven on macOS or by compilation alone:

1. Microphone privacy consent and actual non-silent MIC capture.
2. WASAPI loopback capture from Teams, Zoom, a browser, and common sound devices.
3. Stop/finalize behavior for both WAV writers.
4. whisper.cpp transcription of Chinese/English mixed audio on CPU-only systems.
5. Interactive GUI launch, Windows Defender, and SmartScreen behavior. CI only
   verifies silent install, a non-audio executable smoke mode, and uninstall;
   the package has no signed publisher identity.
6. Long-meeting CPU, memory, storage, and transcription-duration behavior.

Do not describe the Windows package as production-ready until those checks pass.
