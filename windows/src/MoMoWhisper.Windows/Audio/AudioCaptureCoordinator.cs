using MoMoWhisper.Windows.Core;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace MoMoWhisper.Windows.Audio;

internal sealed record CapturedAudio(
    string? MicrophoneCapturePath,
    string? SystemCapturePath);

internal sealed class AudioCaptureCoordinator : IDisposable
{
    private readonly List<AudioCaptureStream> _streams = [];
    private CapturedAudio? _paths;

    public bool IsRecording => _streams.Count > 0;

    public void Start(RecordingPartMetadata part)
    {
        if (IsRecording)
        {
            throw new InvalidOperationException("An audio capture is already active.");
        }

        var microphoneCapturePath = SessionFactory.CapturePathFor(part.MicrophonePath);
        var systemCapturePath = SessionFactory.CapturePathFor(part.SystemAudioPath);
        if (microphoneCapturePath is null && systemCapturePath is null)
        {
            throw new InvalidOperationException("The recording part has no selected audio source.");
        }

        try
        {
            if (microphoneCapturePath is not null)
            {
                using var enumerator = new MMDeviceEnumerator();
                using var endpoint = enumerator.GetDefaultAudioEndpoint(
                    DataFlow.Capture,
                    Role.Multimedia);
                var microphone = new WasapiCapture(
                    endpoint,
                    useEventSync: true,
                    audioBufferMillisecondsLength: 100);
                var stream = new AudioCaptureStream(microphone, microphoneCapturePath);
                stream.Start();
                _streams.Add(stream);

                part.MicrophoneEndpointId = endpoint.ID;
                part.MicrophoneEndpointName = endpoint.FriendlyName;
                part.MicrophoneCaptureFormat = DescribeFormat(microphone.WaveFormat);
            }

            if (systemCapturePath is not null)
            {
                using var enumerator = new MMDeviceEnumerator();
                using var endpoint = enumerator.GetDefaultAudioEndpoint(
                    DataFlow.Render,
                    Role.Multimedia);
                var loopback = new WasapiLoopbackCapture(endpoint);
                var stream = new AudioCaptureStream(loopback, systemCapturePath);
                stream.Start();
                _streams.Add(stream);

                part.SystemAudioEndpointId = endpoint.ID;
                part.SystemAudioEndpointName = endpoint.FriendlyName;
                part.SystemAudioCaptureFormat = DescribeFormat(loopback.WaveFormat);
            }

            _paths = new CapturedAudio(microphoneCapturePath, systemCapturePath);
        }
        catch
        {
            DisposeStreams();
            throw;
        }
    }

    public async Task<CapturedAudio> StopAsync(CancellationToken cancellationToken = default)
    {
        var paths = _paths ?? throw new InvalidOperationException("No audio capture is active.");
        try
        {
            await Task.WhenAll(_streams.Select(stream => stream.StopAsync(cancellationToken)))
                .ConfigureAwait(false);
            return paths;
        }
        finally
        {
            DisposeStreams();
            _paths = null;
        }
    }

    private void DisposeStreams()
    {
        foreach (var stream in _streams)
        {
            stream.Dispose();
        }

        _streams.Clear();
    }

    public void Dispose()
    {
        DisposeStreams();
        _paths = null;
    }

    private static string DescribeFormat(WaveFormat format) =>
        $"{format.SampleRate} Hz, {format.BitsPerSample}-bit, {format.Channels} channel(s), {format.Encoding}";
}
