using System.Text;
using System.Text.Json;

namespace MoMoWhisper.Windows.Core;

public sealed class ArtifactWriter
{
    private readonly AppPaths _paths;

    public ArtifactWriter(AppPaths paths)
    {
        _paths = paths;
    }

    public SessionArtifacts Write(
        MeetingSessionMetadata metadata,
        IReadOnlyList<TranscriptSegment> segments)
    {
        _paths.EnsureCreated();
        var transcriptPath = Path.Combine(metadata.SessionDirectory, "transcript.md");
        var highlightsPath = Path.Combine(metadata.SessionDirectory, "highlights.md");
        var handoffMarkdownPath = Path.Combine(metadata.SessionDirectory, "codex_handoff.md");
        var handoffJsonPath = Path.Combine(metadata.SessionDirectory, "codex_handoff.json");

        var transcript = TranscriptMerger.ToMarkdown(metadata.Title, segments);
        var highlights = LocalSummaryBuilder.Build(metadata.Title, segments, metadata.Warnings);

        metadata.TranscriptPath = transcriptPath;
        metadata.HighlightsPath = highlightsPath;
        metadata.HandoffMarkdownPath = handoffMarkdownPath;
        metadata.HandoffJsonPath = handoffJsonPath;
        metadata.TranscriptCharacterCount = segments.Sum(item => item.Text.Length);
        metadata.HandoffValidity = IsValidHandoff(metadata, segments) ? "valid" : "invalid";
        metadata.LatestValidHandoffUpdated = metadata.HandoffValidity == "valid";

        var payload = new
        {
            schemaVersion = metadata.SchemaVersion,
            meetingId = metadata.SessionId,
            title = metadata.Title,
            handoffStatus = metadata.Status,
            handoffValidity = metadata.HandoffValidity,
            latestValidHandoffUpdated = metadata.LatestValidHandoffUpdated,
            windowsBeta = true,
            transcriptionMode = metadata.TranscriptionMode,
            postStopProcessingStatus = metadata.PostStopProcessingStatus,
            featureParity = metadata.FeatureParity,
            startedAt = metadata.StartedAt,
            endedAt = metadata.EndedAt,
            transcriptPath,
            highlightsPath,
            metadataPath = MetadataStore.MetadataPath(metadata),
            sessionFolderPath = metadata.SessionDirectory,
            recordingParts = metadata.RecordingParts,
            warnings = metadata.Warnings
        };
        var handoffJson = JsonSerializer.Serialize(payload, MetadataStore.JsonOptions);
        var handoffMarkdown = BuildHandoffMarkdown(metadata, transcriptPath, highlightsPath);

        AtomicFile.WriteAllText(transcriptPath, transcript);
        AtomicFile.WriteAllText(highlightsPath, highlights);
        AtomicFile.WriteAllText(handoffMarkdownPath, handoffMarkdown);
        AtomicFile.WriteAllText(handoffJsonPath, handoffJson);
        MetadataStore.Write(metadata);

        AtomicFile.WriteAllText(
            Path.Combine(_paths.HandoffDirectory, "latest_attempt_handoff.md"),
            handoffMarkdown);
        AtomicFile.WriteAllText(
            Path.Combine(_paths.HandoffDirectory, "latest_attempt_handoff.json"),
            handoffJson);

        if (metadata.LatestValidHandoffUpdated)
        {
            AtomicFile.WriteAllText(
                Path.Combine(_paths.HandoffDirectory, "latest_valid_handoff.md"),
                handoffMarkdown);
            AtomicFile.WriteAllText(
                Path.Combine(_paths.HandoffDirectory, "latest_valid_handoff.json"),
                handoffJson);
        }

        return new SessionArtifacts(
            transcriptPath,
            highlightsPath,
            handoffJsonPath,
            handoffMarkdownPath,
            transcript,
            highlights);
    }

    private static string BuildHandoffMarkdown(
        MeetingSessionMetadata metadata,
        string transcriptPath,
        string highlightsPath)
    {
        var builder = new StringBuilder();
        builder.AppendLine("# MoMoWhisper Windows Beta Codex Handoff");
        builder.AppendLine();
        builder.AppendLine($"- 狀態：{metadata.Status}");
        builder.AppendLine($"- Post-stop 處理：{metadata.PostStopProcessingStatus}");
        builder.AppendLine($"- 交接有效性：{metadata.HandoffValidity}");
        builder.AppendLine($"- 會議：{metadata.Title}");
        builder.AppendLine($"- 開始：{metadata.StartedAt:O}");
        builder.AppendLine($"- 結束：{metadata.EndedAt:O}");
        builder.AppendLine("- 轉錄方式：停止錄音後，使用隨安裝包提供的 whisper.cpp CLI + multilingual base model");
        builder.AppendLine("- 產品邊界：Windows Beta；不是 macOS 版功能等價實作");
        builder.AppendLine($"- 逐字稿：{transcriptPath}");
        builder.AppendLine($"- 本地機械摘錄：{highlightsPath}");
        builder.AppendLine($"- Metadata：{MetadataStore.MetadataPath(metadata)}");
        builder.AppendLine($"- Session：{metadata.SessionDirectory}");
        builder.AppendLine();
        builder.AppendLine("`latest_attempt` 一律代表最近一次處理嘗試；只有逐字稿非空、且所有要求的音源都完成轉錄時才更新 `latest_valid`。");
        builder.AppendLine("錄音來源保持獨立；逐字稿以 `[MIC]` 與 `[SYS]` 標示。若 warnings 非空，必須先核對 metadata.json 再使用內容。");
        return builder.ToString();
    }

    private static bool IsValidHandoff(
        MeetingSessionMetadata metadata,
        IReadOnlyCollection<TranscriptSegment> segments)
    {
        if (segments.Count == 0 || metadata.RecordingParts.Count == 0)
        {
            return false;
        }

        return metadata.RecordingParts.All(part =>
            (part.MicrophoneRequested || part.SystemAudioRequested)
            && (!part.MicrophoneRequested
                || string.Equals(
                    part.MicrophoneTranscriptionStatus,
                    "completed",
                    StringComparison.Ordinal))
            && (!part.SystemAudioRequested
                || string.Equals(
                    part.SystemAudioTranscriptionStatus,
                    "completed",
                    StringComparison.Ordinal)));
    }
}
