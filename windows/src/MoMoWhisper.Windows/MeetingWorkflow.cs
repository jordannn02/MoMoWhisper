using MoMoWhisper.Windows.Audio;
using MoMoWhisper.Windows.Core;

namespace MoMoWhisper.Windows;

internal sealed class MeetingWorkflow : IDisposable
{
    private readonly SessionFactory _sessionFactory;
    private readonly AudioCaptureCoordinator _audioCapture = new();
    private readonly ArtifactWriter _artifactWriter;
    private readonly WhisperCliTranscriber _transcriber;
    private ActiveMeeting? _active;

    public MeetingWorkflow(AppPaths paths, WhisperRuntime runtime)
    {
        _sessionFactory = new SessionFactory(paths);
        _artifactWriter = new ArtifactWriter(paths);
        _transcriber = new WhisperCliTranscriber(runtime);
    }

    public bool IsRecording => _active is not null && _audioCapture.IsRecording;

    public MeetingSessionMetadata Start(
        string? title,
        bool captureMicrophone,
        bool captureSystemAudio)
    {
        if (_active is not null)
        {
            throw new InvalidOperationException("A meeting session is already active.");
        }

        var session = _sessionFactory.CreateSession(title);
        var part = _sessionFactory.CreateRecordingPart(
            session,
            sequence: 1,
            includeMicrophone: captureMicrophone,
            includeSystemAudio: captureSystemAudio);
        session.RecordingParts.Add(part);
        session.Status = "starting";
        MetadataStore.Write(session);

        try
        {
            _audioCapture.Start(part);
            part.Status = "recording";
            session.Status = "recording";
            MetadataStore.Write(session);
            _active = new ActiveMeeting(session, part);
            return session;
        }
        catch (Exception error)
        {
            part.Status = "start-failed";
            part.EndedAt = DateTimeOffset.Now;
            session.Status = "start-failed";
            session.EndedAt = DateTimeOffset.Now;
            session.Warnings.Add($"Audio capture could not start: {error.Message}");
            MetadataStore.Write(session);
            throw;
        }
    }

    public async Task<WorkflowResult> StopAndTranscribeAsync(
        IProgress<string>? progress = null,
        CancellationToken cancellationToken = default)
    {
        var active = _active ?? throw new InvalidOperationException("No meeting session is active.");
        _active = null;
        var session = active.Session;
        var part = active.Part;
        IReadOnlyList<TranscriptSegment> microphoneSegments = [];
        IReadOnlyList<TranscriptSegment> systemSegments = [];

        progress?.Report("Stopping separate MIC/SYS audio writers...");
        CapturedAudio captured;
        try
        {
            // Audio finalization is deliberately non-cancellable. A user-requested
            // cancellation takes effect immediately after both WAV writers stop.
            captured = await _audioCapture.StopAsync(CancellationToken.None).ConfigureAwait(false);
            part.Status = "captured";
        }
        catch (Exception error)
        {
            part.Status = "capture-warning";
            session.Warnings.Add($"Audio capture stop reported an error: {error.Message}");
            captured = new CapturedAudio(
                SessionFactory.CapturePathFor(part.MicrophonePath),
                SessionFactory.CapturePathFor(part.SystemAudioPath));
        }

        part.EndedAt = DateTimeOffset.Now;
        session.EndedAt = part.EndedAt;
        session.Status = "post-stop-processing";
        session.PostStopProcessingStatus = "normalizing-audio";
        MetadataStore.Write(session);

        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            part.MicrophonePath = await NormalizeOrKeepCaptureAsync(
                captured.MicrophoneCapturePath,
                part.MicrophonePath,
                "MIC",
                session,
                progress,
                cancellationToken).ConfigureAwait(false);
            part.SystemAudioPath = await NormalizeOrKeepCaptureAsync(
                captured.SystemCapturePath,
                part.SystemAudioPath,
                "SYS",
                session,
                progress,
                cancellationToken).ConfigureAwait(false);

            part.TranscriptionStatus = "processing";
            session.Status = "transcribing-after-stop";
            session.PostStopProcessingStatus = "transcribing";
            MetadataStore.Write(session);
            var timelineOffset = Math.Max(
                0,
                (long)(part.StartedAt - session.StartedAt).TotalMilliseconds);

            microphoneSegments = await TranscribeSourceAsync(
                part.MicrophonePath,
                part.MicrophoneRequested,
                TranscriptSource.Microphone,
                timelineOffset,
                part,
                session,
                progress,
                cancellationToken).ConfigureAwait(false);
            systemSegments = await TranscribeSourceAsync(
                part.SystemAudioPath,
                part.SystemAudioRequested,
                TranscriptSource.SystemAudio,
                timelineOffset,
                part,
                session,
                progress,
                cancellationToken).ConfigureAwait(false);

            var merged = TranscriptMerger.Merge(microphoneSegments, systemSegments);
            UpdateAggregateTranscriptionStatus(part);
            part.Status = "ended";
            session.PostStopProcessingStatus = part.TranscriptionStatus == "completed"
                ? "completed"
                : "completed-incomplete-transcript";
            session.Status = session.Warnings.Count == 0
                ? "ended"
                : "ended-with-warnings";

            progress?.Report("Writing transcript, metadata, local highlights, and Codex handoff...");
            var artifacts = _artifactWriter.Write(session, merged);
            progress?.Report(MetadataReadyText(session));
            return new WorkflowResult(session, artifacts, merged);
        }
        catch (OperationCanceledException error)
        {
            MarkPendingSources(part, "cancelled");
            UpdateAggregateTranscriptionStatus(part);
            part.Status = "post-stop-cancelled";
            session.Status = "post-stop-cancelled";
            session.PostStopProcessingStatus = "cancelled";
            session.PostStopCancellationRequestedAt = DateTimeOffset.Now;
            session.Warnings.Add(
                $"Post-stop processing was cancelled by the user. Audio and diagnostic output were retained. {error.Message}");
            _artifactWriter.Write(
                session,
                TranscriptMerger.Merge(microphoneSegments, systemSegments));
            progress?.Report("Post-stop processing cancelled; latest_attempt was updated, latest_valid was not.");
            throw;
        }
        catch (Exception error)
        {
            MarkPendingSources(part, "failed");
            UpdateAggregateTranscriptionStatus(part);
            part.Status = "post-stop-failed";
            session.Status = "post-stop-failed";
            session.PostStopProcessingStatus = "failed";
            session.Warnings.Add($"Post-stop processing failed: {error.Message}");
            _artifactWriter.Write(
                session,
                TranscriptMerger.Merge(microphoneSegments, systemSegments));
            throw;
        }
    }

    private async Task<string?> NormalizeOrKeepCaptureAsync(
        string? capturePath,
        string? destinationPath,
        string label,
        MeetingSessionMetadata session,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        if (capturePath is null || destinationPath is null)
        {
            return null;
        }

        if (!File.Exists(capturePath))
        {
            session.Warnings.Add($"{label} capture file is missing: {capturePath}");
            return null;
        }

        try
        {
            progress?.Report($"Normalizing {label} audio for whisper.cpp...");
            return await AudioNormalizer.NormalizeAsync(
                capturePath,
                destinationPath,
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error)
        {
            session.Warnings.Add(
                $"{label} normalization failed; the original capture WAV was kept: {error.Message}");
            return capturePath;
        }
    }

    private async Task<IReadOnlyList<TranscriptSegment>> TranscribeSourceAsync(
        string? audioPath,
        bool requested,
        TranscriptSource source,
        long timelineOffset,
        RecordingPartMetadata part,
        MeetingSessionMetadata session,
        IProgress<string>? progress,
        CancellationToken cancellationToken)
    {
        if (!requested)
        {
            return [];
        }

        if (audioPath is null)
        {
            SetSourceTranscriptionStatus(part, source, "missing-audio");
            session.Warnings.Add(
                $"[{TranscriptMerger.SourceLabel(source)}] transcription was not attempted because its audio file is missing.");
            return [];
        }

        try
        {
            SetSourceTranscriptionStatus(part, source, "processing");
            MetadataStore.Write(session);
            progress?.Report($"Transcribing [{TranscriptMerger.SourceLabel(source)}] after stop...");
            var segments = await _transcriber.TranscribeAsync(
                audioPath,
                source,
                timelineOffset,
                cancellationToken).ConfigureAwait(false);
            if (segments.Count == 0)
            {
                SetSourceTranscriptionStatus(part, source, "no-speech");
                session.Warnings.Add(
                    $"[{TranscriptMerger.SourceLabel(source)}] produced no speech segments; this attempt cannot update latest_valid.");
                return [];
            }

            SetSourceTranscriptionStatus(part, source, "completed");
            return segments;
        }
        catch (OperationCanceledException)
        {
            SetSourceTranscriptionStatus(part, source, "cancelled");
            throw;
        }
        catch (Exception error)
        {
            SetSourceTranscriptionStatus(part, source, "failed");
            session.Warnings.Add(
                $"[{TranscriptMerger.SourceLabel(source)}] transcription failed: {error.Message}");
            return [];
        }
    }

    private static void SetSourceTranscriptionStatus(
        RecordingPartMetadata part,
        TranscriptSource source,
        string status)
    {
        if (source == TranscriptSource.Microphone)
        {
            part.MicrophoneTranscriptionStatus = status;
        }
        else
        {
            part.SystemAudioTranscriptionStatus = status;
        }
    }

    private static void MarkPendingSources(RecordingPartMetadata part, string status)
    {
        if (part.MicrophoneRequested
            && part.MicrophoneTranscriptionStatus is "pending" or "processing")
        {
            part.MicrophoneTranscriptionStatus = status;
        }

        if (part.SystemAudioRequested
            && part.SystemAudioTranscriptionStatus is "pending" or "processing")
        {
            part.SystemAudioTranscriptionStatus = status;
        }
    }

    private static void UpdateAggregateTranscriptionStatus(RecordingPartMetadata part)
    {
        var required = new List<string>();
        if (part.MicrophoneRequested)
        {
            required.Add(part.MicrophoneTranscriptionStatus);
        }

        if (part.SystemAudioRequested)
        {
            required.Add(part.SystemAudioTranscriptionStatus);
        }

        part.TranscriptionStatus = required.Count > 0
            && required.All(status => string.Equals(status, "completed", StringComparison.Ordinal))
                ? "completed"
                : required.Any(status => string.Equals(status, "cancelled", StringComparison.Ordinal))
                    ? "cancelled"
                    : "incomplete";
    }

    private static string MetadataReadyText(MeetingSessionMetadata session) =>
        session.LatestValidHandoffUpdated
            ? "Done. latest_attempt and latest_valid were updated."
            : "Done with an incomplete transcript. latest_attempt was updated; latest_valid was preserved.";

    public void Dispose()
    {
        _audioCapture.Dispose();
    }

    private sealed record ActiveMeeting(
        MeetingSessionMetadata Session,
        RecordingPartMetadata Part);

}
