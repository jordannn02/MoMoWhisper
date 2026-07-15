# Third-party notices — MoMoWhisper Windows Beta

This file records dependencies bundled or referenced only by the Windows Beta.
It does not modify the root project license.

## Microsoft .NET 8

- Project: <https://github.com/dotnet/runtime>
- SDK pinned by the release workflow: `8.0.423`
- Runtime resolved by that SDK at review time: `8.0.29`
- Runtime packaging mode: self-contained `win-x64`
- License: MIT, <https://github.com/dotnet/runtime/blob/main/LICENSE.TXT>
- Upstream notices: <https://github.com/dotnet/runtime/blob/main/THIRD-PARTY-NOTICES.TXT>
- Use: managed runtime and Windows desktop framework shipped with the
  self-contained application.

The self-contained publish includes Microsoft .NET runtime components; users do
not need to install .NET separately. Those components retain their upstream
licenses and notices.

## NAudio 2.3.0

- Project: <https://github.com/naudio/NAudio>
- Package: <https://www.nuget.org/packages/NAudio/2.3.0>
- License declared by the package: MIT
- Use: Windows microphone capture, WASAPI loopback, WAV writing, and Media
  Foundation resampling.

```text
Copyright 2020 Mark Heath

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## whisper.cpp v1.9.1

- Project: <https://github.com/ggml-org/whisper.cpp>
- Source tag: <https://github.com/ggml-org/whisper.cpp/releases/tag/v1.9.1>
- Pinned commit: `f049fff95a089aa9969deb009cdd4892b3e74916`
- Pinned source ZIP SHA-256: `58347c4dc92142c47b6d6e5a2a7e1b00b501c9bf8cdaff7f089e49ae59eb3a44`
- License: MIT
- Use: bundled CPU transcription CLI.

The workflow builds `whisper-cli.exe` from the pinned source with static
whisper/ggml libraries and the static MSVC runtime. It packages only that
executable, rejects whisper/ggml or MSVC runtime DLL imports with `dumpbin`, and
does not bundle the upstream server, tests, SDL2, or a separate Visual C++
Redistributable installer.

```text
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Whisper multilingual base model

- Repository: <https://huggingface.co/ggerganov/whisper.cpp>
- File: `ggml-base.bin`
- Download URL: <https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin>
- Size observed at pinning: 147,951,465 bytes
- SHA-256: `60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe`
- Repository license declaration: MIT
- Use: multilingual local speech recognition.

The model is a converted OpenAI Whisper model. The upstream OpenAI Whisper MIT
notice is reproduced below.

```text
MIT License

Copyright (c) 2022 OpenAI

Permission is hereby granted, free of charge, to any person obtaining a copy of
this software and associated documentation files (the "Software"), to deal in
the Software without restriction, including without limitation the rights to
use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software is furnished to do so,
subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Inno Setup 6.7.1

- Project: <https://jrsoftware.org/isinfo.php>
- Source and license: <https://github.com/jrsoftware/issrc/blob/main/license.txt>
- Use: installer build tool and setup runtime.

Inno Setup runs only on the GitHub Windows builder; the compiler itself is not
included in the application payload. The generated setup executable contains
Inno Setup runtime code under its upstream license. That license permits use,
including commercial applications, and redistribution subject to its notice
and attribution conditions; it is not a MoMoWhisper commercial-license grant.

The release workflow verifies the source archive and model against the hashes
above before building or packaging. If an upstream artifact changes, update
this file and the workflow only after reviewing the new source/model and
checksum.
