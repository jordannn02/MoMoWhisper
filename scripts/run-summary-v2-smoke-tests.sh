#!/usr/bin/env bash

set -euo pipefail

export TMPDIR=/tmp
build_dir="$(mktemp -d /tmp/momowhisper-summary-v2-smoke.XXXXXX)"
trap 'rm -rf "$build_dir"' EXIT

swiftc \
  -emit-library \
  -emit-module \
  -module-name MoMoWhisperSummaryCore \
  Sources/MoMoWhisperSummaryCore/*.swift \
  -emit-module-path "$build_dir/MoMoWhisperSummaryCore.swiftmodule" \
  -o "$build_dir/libMoMoWhisperSummaryCore.dylib"

swiftc \
  -emit-library \
  -emit-module \
  -module-name MoMoWhisperSessionCore \
  Sources/MoMoWhisperSessionCore/*.swift \
  -emit-module-path "$build_dir/MoMoWhisperSessionCore.swiftmodule" \
  -o "$build_dir/libMoMoWhisperSessionCore.dylib"

swiftc \
  -I "$build_dir" \
  -L "$build_dir" \
  -lMoMoWhisperSummaryCore \
  Sources/MoMoWhisper/DeepSeekMeetingSummarizer.swift \
  Sources/MoMoWhisper/SummaryProviderDeltaValidator.swift \
  Tests/MoMoWhisperParserSmokeTests/main.swift \
  -o "$build_dir/momowhisper-parser-smoke"

DYLD_LIBRARY_PATH="$build_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  "$build_dir/momowhisper-parser-smoke"

swiftc \
  -I "$build_dir" \
  -L "$build_dir" \
  -lMoMoWhisperSummaryCore \
  Sources/MoMoWhisper/DeepSeekMeetingSummarizer.swift \
  Tests/MoMoWhisperRetryCancellationSmokeTests/main.swift \
  -o "$build_dir/momowhisper-retry-cancellation-smoke"

DYLD_LIBRARY_PATH="$build_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  "$build_dir/momowhisper-retry-cancellation-smoke"

swiftc \
  Sources/MoMoWhisper/SummaryPipelineIdentity.swift \
  Tests/MoMoWhisperPipelineSmokeTests/main.swift \
  -o "$build_dir/momowhisper-summary-pipeline-smoke"

"$build_dir/momowhisper-summary-pipeline-smoke"

swiftc \
  -I "$build_dir" \
  -L "$build_dir" \
  -lMoMoWhisperSummaryCore \
  Sources/MoMoWhisper/SummaryFallbackProjection.swift \
  Tests/MoMoWhisperFallbackProjectionSmokeTests/main.swift \
  -o "$build_dir/momowhisper-fallback-projection-smoke"

DYLD_LIBRARY_PATH="$build_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  "$build_dir/momowhisper-fallback-projection-smoke"

swiftc \
  Sources/MoMoWhisper/SummaryErrorSanitizer.swift \
  Tests/MoMoWhisperErrorSanitizerSmokeTests/main.swift \
  -o "$build_dir/momowhisper-error-sanitizer-smoke"

"$build_dir/momowhisper-error-sanitizer-smoke"

swiftc \
  -I "$build_dir" \
  -L "$build_dir" \
  -lMoMoWhisperSummaryCore \
  -lMoMoWhisperSessionCore \
  Sources/MoMoWhisper/DeepSeekMeetingSummarizer.swift \
  Sources/MoMoWhisper/SummaryPipelineIdentity.swift \
  Sources/MoMoWhisper/MoMoWhisperStorage.swift \
  Sources/MoMoWhisper/MeetingSessionStore.swift \
  Sources/MoMoWhisper/MeetingArtifactExporter.swift \
  Tests/MoMoWhisperSessionStoreSmokeTests/main.swift \
  -o "$build_dir/momowhisper-session-store-smoke"

DYLD_LIBRARY_PATH="$build_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  "$build_dir/momowhisper-session-store-smoke"

swiftc \
  -parse-as-library \
  -I "$build_dir" \
  -L "$build_dir" \
  -lMoMoWhisperSessionCore \
  Tests/MoMoWhisperPersistenceSmokeTests/main.swift \
  -o "$build_dir/momowhisper-persistence-smoke"

DYLD_LIBRARY_PATH="$build_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}" \
  "$build_dir/momowhisper-persistence-smoke"

printf '%s\n' "Summary V2 production smoke tests passed"
