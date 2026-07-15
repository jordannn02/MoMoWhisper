using MoMoWhisper.Windows.Core;

namespace MoMoWhisper.Windows.Core.Tests;

public sealed class TranscriptMergeTests
{
    [Fact]
    public void MergeOrdersSourcesByAudioTimeAndKeepsLabels()
    {
        var microphone = new[]
        {
            new TranscriptSegment(TranscriptSource.Microphone, 1_000, 1_500, "hello from mic"),
            new TranscriptSegment(TranscriptSource.Microphone, 3_000, 3_500, "later mic")
        };
        var system = new[]
        {
            new TranscriptSegment(TranscriptSource.SystemAudio, 2_000, 2_500, "system reply")
        };

        var merged = TranscriptMerger.Merge(microphone, system);
        var markdown = TranscriptMerger.ToMarkdown("Merge test", merged);

        Assert.Equal(
            new[] { "hello from mic", "system reply", "later mic" },
            merged.Select(item => item.Text));
        Assert.Contains("[00:00:01.000] [MIC] hello from mic", markdown);
        Assert.Contains("[00:00:02.000] [SYS] system reply", markdown);
    }

    [Fact]
    public void WhisperJsonOffsetsAreParsedAndShiftedOntoTheSessionTimeline()
    {
        const string json = """
        {
          "transcription": [
            {
              "timestamps": { "from": "00:00:00,000", "to": "00:00:01,200" },
              "offsets": { "from": 0, "to": 1200 },
              "text": "  hello   world  "
            }
          ]
        }
        """;

        var parsed = WhisperJsonParser.Parse(json, TranscriptSource.SystemAudio, 2_500);

        var segment = Assert.Single(parsed);
        Assert.Equal(2_500, segment.StartMilliseconds);
        Assert.Equal(3_700, segment.EndMilliseconds);
        Assert.Equal("hello world", segment.Text);
        Assert.Equal(TranscriptSource.SystemAudio, segment.Source);
    }

    [Fact]
    public void WhisperJsonWithoutRequiredTranscriptionArrayIsRejected()
    {
        const string json = """{ "result": "unexpected schema" }""";

        var error = Assert.Throws<InvalidDataException>(() =>
            WhisperJsonParser.Parse(json, TranscriptSource.Microphone));

        Assert.Contains("transcription array", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ValidWhisperJsonWithNoSpeechReturnsNoSegmentsForWorkflowClassification()
    {
        const string json = """{ "transcription": [] }""";

        var segments = WhisperJsonParser.Parse(json, TranscriptSource.Microphone);

        Assert.Empty(segments);
    }
}
