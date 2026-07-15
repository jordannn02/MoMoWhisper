using System.Text;
using System.Text.Json;

namespace MoMoWhisper.Windows.Core;

public static class WhisperJsonParser
{
    public static IReadOnlyList<TranscriptSegment> Parse(
        string json,
        TranscriptSource source,
        long timelineOffsetMilliseconds = 0)
    {
        using var document = JsonDocument.Parse(json);
        if (!document.RootElement.TryGetProperty("transcription", out var transcription)
            || transcription.ValueKind != JsonValueKind.Array)
        {
            throw new InvalidDataException(
                "whisper.cpp JSON is missing the required transcription array.");
        }

        var segments = new List<TranscriptSegment>();
        foreach (var item in transcription.EnumerateArray())
        {
            if (!item.TryGetProperty("text", out var textElement))
            {
                continue;
            }

            var text = NormalizeText(textElement.GetString());
            if (text.Length == 0)
            {
                continue;
            }

            var start = 0L;
            var end = 0L;
            if (item.TryGetProperty("offsets", out var offsets))
            {
                if (offsets.TryGetProperty("from", out var fromElement))
                {
                    start = fromElement.GetInt64();
                }

                if (offsets.TryGetProperty("to", out var toElement))
                {
                    end = toElement.GetInt64();
                }
            }

            var normalizedStart = Math.Max(0, start);
            var normalizedEnd = Math.Max(normalizedStart, end);
            segments.Add(new TranscriptSegment(
                source,
                timelineOffsetMilliseconds + normalizedStart,
                timelineOffsetMilliseconds + normalizedEnd,
                text));
        }

        return segments;
    }

    private static string NormalizeText(string? text) =>
        string.Join(' ', (text ?? string.Empty)
            .Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
}

public static class TranscriptMerger
{
    public static IReadOnlyList<TranscriptSegment> Merge(
        IEnumerable<TranscriptSegment> microphone,
        IEnumerable<TranscriptSegment> systemAudio) =>
        microphone
            .Concat(systemAudio)
            .OrderBy(segment => segment.StartMilliseconds)
            .ThenBy(segment => SourceOrder(segment.Source))
            .ThenBy(segment => segment.EndMilliseconds)
            .ToArray();

    public static string ToMarkdown(string title, IEnumerable<TranscriptSegment> segments)
    {
        var ordered = segments.ToArray();
        var builder = new StringBuilder();
        builder.AppendLine($"# {title}");
        builder.AppendLine();
        builder.AppendLine("> MoMoWhisper Windows Beta：錄音停止後才使用 bundled whisper.cpp 轉錄；不是 macOS 版即時功能的等價實作。");
        builder.AppendLine();

        if (ordered.Length == 0)
        {
            builder.AppendLine("尚未產生可用逐字稿。請查看 metadata.json 的 warnings 與 transcriptionStatus。");
            return builder.ToString();
        }

        foreach (var segment in ordered)
        {
            builder.Append('[')
                .Append(FormatTimestamp(segment.StartMilliseconds))
                .Append("] [")
                .Append(SourceLabel(segment.Source))
                .Append("] ")
                .AppendLine(segment.Text);
        }

        return builder.ToString();
    }

    public static string SourceLabel(TranscriptSource source) => source switch
    {
        TranscriptSource.Microphone => "MIC",
        TranscriptSource.SystemAudio => "SYS",
        _ => "UNK"
    };

    public static string FormatTimestamp(long milliseconds)
    {
        var duration = TimeSpan.FromMilliseconds(Math.Max(0, milliseconds));
        return $"{(long)duration.TotalHours:00}:{duration.Minutes:00}:{duration.Seconds:00}.{duration.Milliseconds:000}";
    }

    private static int SourceOrder(TranscriptSource source) => source switch
    {
        TranscriptSource.Microphone => 0,
        TranscriptSource.SystemAudio => 1,
        _ => 2
    };
}

public static class LocalSummaryBuilder
{
    public static string Build(
        string title,
        IReadOnlyCollection<TranscriptSegment> segments,
        IReadOnlyCollection<string> warnings)
    {
        var excerpts = segments
            .Select(segment => segment.Text.Trim())
            .Where(text => text.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .Take(8)
            .ToArray();

        var builder = new StringBuilder();
        builder.AppendLine($"# {title} — Windows Beta 本地重點");
        builder.AppendLine();
        builder.AppendLine("> 本檔是保守的機械摘錄，不是 AI 語意摘要；不推定決策、負責人或行動項。");
        builder.AppendLine();
        builder.AppendLine($"- 逐字稿片段數：{segments.Count}");
        builder.AppendLine($"- 來源：{string.Join(" / ", segments.Select(item => TranscriptMerger.SourceLabel(item.Source)).Distinct())}");
        builder.AppendLine($"- 警告數：{warnings.Count}");
        builder.AppendLine();
        builder.AppendLine("## 開頭摘錄");
        builder.AppendLine();

        if (excerpts.Length == 0)
        {
            builder.AppendLine("- 尚未產生可摘錄內容。");
        }
        else
        {
            foreach (var excerpt in excerpts)
            {
                builder.Append("- ").AppendLine(excerpt);
            }
        }

        if (warnings.Count > 0)
        {
            builder.AppendLine();
            builder.AppendLine("## 驗證警告");
            builder.AppendLine();
            foreach (var warning in warnings)
            {
                builder.Append("- ").AppendLine(warning);
            }
        }

        return builder.ToString();
    }
}
