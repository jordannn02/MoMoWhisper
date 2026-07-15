namespace MoMoWhisper.Windows.Core;

public enum TranscriptSource
{
    Microphone,
    SystemAudio
}

public sealed record TranscriptSegment(
    TranscriptSource Source,
    long StartMilliseconds,
    long EndMilliseconds,
    string Text);

public sealed class RecordingPartMetadata
{
    public int Sequence { get; set; }
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset? EndedAt { get; set; }
    public string Status { get; set; } = "created";
    public string? MicrophonePath { get; set; }
    public string? SystemAudioPath { get; set; }
    public bool MicrophoneRequested { get; set; }
    public bool SystemAudioRequested { get; set; }
    public string MicrophoneTranscriptionStatus { get; set; } = "not-requested";
    public string SystemAudioTranscriptionStatus { get; set; } = "not-requested";
    public string? MicrophoneEndpointId { get; set; }
    public string? MicrophoneEndpointName { get; set; }
    public string? MicrophoneCaptureFormat { get; set; }
    public string? SystemAudioEndpointId { get; set; }
    public string? SystemAudioEndpointName { get; set; }
    public string? SystemAudioCaptureFormat { get; set; }
    public string TranscriptionStatus { get; set; } = "pending";
}

public sealed class MeetingSessionMetadata
{
    public string SchemaVersion { get; set; } = "momowhisper.windows-beta.v2";
    public Guid SessionId { get; set; }
    public string Title { get; set; } = "Untitled meeting";
    public string Platform { get; set; } = "windows-x64";
    public string ProductStatus { get; set; } = "Windows Beta";
    public string TranscriptionMode { get; set; } = "post-stop";
    public string FeatureParity { get; set; } = "not equivalent to the macOS app";
    public DateTimeOffset StartedAt { get; set; }
    public DateTimeOffset? EndedAt { get; set; }
    public string Status { get; set; } = "created";
    public string PostStopProcessingStatus { get; set; } = "not-started";
    public DateTimeOffset? PostStopCancellationRequestedAt { get; set; }
    public string HandoffValidity { get; set; } = "not-evaluated";
    public bool LatestValidHandoffUpdated { get; set; }
    public string SessionDirectory { get; set; } = string.Empty;
    public string? TranscriptPath { get; set; }
    public string? HighlightsPath { get; set; }
    public string? HandoffJsonPath { get; set; }
    public string? HandoffMarkdownPath { get; set; }
    public int TranscriptCharacterCount { get; set; }
    public string WhisperModel { get; set; } = "ggml-base.bin";
    public List<RecordingPartMetadata> RecordingParts { get; set; } = [];
    public List<string> Warnings { get; set; } = [];
}

public sealed record SessionArtifacts(
    string TranscriptPath,
    string HighlightsPath,
    string HandoffJsonPath,
    string HandoffMarkdownPath,
    string TranscriptMarkdown,
    string HighlightsMarkdown);

public sealed record WorkflowResult(
    MeetingSessionMetadata Metadata,
    SessionArtifacts Artifacts,
    IReadOnlyList<TranscriptSegment> Segments);
