using MoMoWhisper.Windows.Core;

namespace MoMoWhisper.Windows.Core.Tests;

public sealed class MetadataTests
{
    [Fact]
    public void MetadataRoundTripPreservesBetaAndRecordingPartBoundaries()
    {
        using var temporary = new TemporaryDirectory();
        var metadata = new MeetingSessionMetadata
        {
            SessionId = Guid.Parse("33333333-3333-3333-3333-333333333333"),
            Title = "metadata test",
            StartedAt = DateTimeOffset.Parse("2026-07-15T09:00:00+00:00"),
            EndedAt = DateTimeOffset.Parse("2026-07-15T09:05:00+00:00"),
            SessionDirectory = temporary.Path,
            Status = "ended"
        };
        metadata.RecordingParts.Add(new RecordingPartMetadata
        {
            Sequence = 1,
            StartedAt = metadata.StartedAt,
            EndedAt = metadata.EndedAt,
            Status = "ended",
            MicrophonePath = System.IO.Path.Combine(temporary.Path, "part-001-mic.wav"),
            SystemAudioPath = System.IO.Path.Combine(temporary.Path, "part-001-sys.wav"),
            TranscriptionStatus = "completed"
        });

        MetadataStore.Write(metadata);
        var decoded = MetadataStore.Read(MetadataStore.MetadataPath(metadata));

        Assert.Equal("momowhisper.windows-beta.v2", decoded.SchemaVersion);
        Assert.Equal("Windows Beta", decoded.ProductStatus);
        Assert.Equal("post-stop", decoded.TranscriptionMode);
        Assert.True(decoded.FeatureParity.Contains("not equivalent", StringComparison.OrdinalIgnoreCase));
        var part = Assert.Single(decoded.RecordingParts);
        Assert.EndsWith("part-001-mic.wav", part.MicrophonePath!, StringComparison.OrdinalIgnoreCase);
        Assert.EndsWith("part-001-sys.wav", part.SystemAudioPath!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void ArtifactWriterCreatesTranscriptHighlightsMetadataAndBothHandoffs()
    {
        using var temporary = new TemporaryDirectory();
        var paths = new AppPaths(
            temporary.Path,
            System.IO.Path.Combine(temporary.Path, "Meetings"),
            System.IO.Path.Combine(temporary.Path, "CodexHandoff"));
        paths.EnsureCreated();
        var sessionDirectory = System.IO.Path.Combine(paths.MeetingsDirectory, "session");
        Directory.CreateDirectory(sessionDirectory);
        var metadata = new MeetingSessionMetadata
        {
            SessionId = Guid.NewGuid(),
            Title = "artifact test",
            StartedAt = DateTimeOffset.UtcNow,
            EndedAt = DateTimeOffset.UtcNow,
            SessionDirectory = sessionDirectory,
            Status = "ended"
        };
        metadata.RecordingParts.Add(new RecordingPartMetadata
        {
            Sequence = 1,
            StartedAt = metadata.StartedAt,
            EndedAt = metadata.EndedAt,
            Status = "ended",
            MicrophoneRequested = true,
            SystemAudioRequested = true,
            MicrophoneTranscriptionStatus = "completed",
            SystemAudioTranscriptionStatus = "completed",
            TranscriptionStatus = "completed"
        });
        var segments = new[]
        {
            new TranscriptSegment(TranscriptSource.Microphone, 0, 500, "first line"),
            new TranscriptSegment(TranscriptSource.SystemAudio, 500, 900, "second line")
        };

        var artifacts = new ArtifactWriter(paths).Write(metadata, segments);

        Assert.True(File.Exists(artifacts.TranscriptPath));
        Assert.True(File.Exists(artifacts.HighlightsPath));
        Assert.True(File.Exists(artifacts.HandoffJsonPath));
        Assert.True(File.Exists(artifacts.HandoffMarkdownPath));
        Assert.True(File.Exists(MetadataStore.MetadataPath(metadata)));
        Assert.True(File.Exists(System.IO.Path.Combine(paths.HandoffDirectory, "latest_attempt_handoff.json")));
        Assert.True(File.Exists(System.IO.Path.Combine(paths.HandoffDirectory, "latest_valid_handoff.json")));
        Assert.Equal("valid", metadata.HandoffValidity);
        Assert.True(metadata.LatestValidHandoffUpdated);
        Assert.Contains("[MIC] first line", artifacts.TranscriptMarkdown);
        Assert.Contains("[SYS] second line", artifacts.TranscriptMarkdown);
    }

    [Fact]
    public void InvalidAttemptUpdatesLatestAttemptButPreservesLatestValid()
    {
        using var temporary = new TemporaryDirectory();
        var paths = new AppPaths(
            temporary.Path,
            System.IO.Path.Combine(temporary.Path, "Meetings"),
            System.IO.Path.Combine(temporary.Path, "CodexHandoff"));
        paths.EnsureCreated();
        var writer = new ArtifactWriter(paths);

        var valid = CreateSession(paths, "valid meeting", "completed");
        writer.Write(
            valid,
            [new TranscriptSegment(TranscriptSource.Microphone, 0, 500, "trusted text")]);
        var latestValidPath = System.IO.Path.Combine(
            paths.HandoffDirectory,
            "latest_valid_handoff.json");
        var originalLatestValid = File.ReadAllText(latestValidPath);

        var invalid = CreateSession(paths, "silent attempt", "no-speech");
        invalid.Warnings.Add("[MIC] produced no speech segments.");
        writer.Write(invalid, []);

        var latestAttempt = File.ReadAllText(System.IO.Path.Combine(
            paths.HandoffDirectory,
            "latest_attempt_handoff.json"));
        Assert.Contains("silent attempt", latestAttempt);
        Assert.Equal(originalLatestValid, File.ReadAllText(latestValidPath));
        Assert.Equal("invalid", invalid.HandoffValidity);
        Assert.False(invalid.LatestValidHandoffUpdated);
    }

    private static MeetingSessionMetadata CreateSession(
        AppPaths paths,
        string title,
        string sourceStatus)
    {
        var sessionDirectory = System.IO.Path.Combine(
            paths.MeetingsDirectory,
            Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(sessionDirectory);
        var now = DateTimeOffset.UtcNow;
        var metadata = new MeetingSessionMetadata
        {
            SessionId = Guid.NewGuid(),
            Title = title,
            StartedAt = now,
            EndedAt = now,
            SessionDirectory = sessionDirectory,
            Status = "ended"
        };
        metadata.RecordingParts.Add(new RecordingPartMetadata
        {
            Sequence = 1,
            StartedAt = now,
            EndedAt = now,
            Status = "ended",
            MicrophoneRequested = true,
            MicrophoneTranscriptionStatus = sourceStatus,
            TranscriptionStatus = sourceStatus == "completed" ? "completed" : "incomplete"
        });
        return metadata;
    }
}
