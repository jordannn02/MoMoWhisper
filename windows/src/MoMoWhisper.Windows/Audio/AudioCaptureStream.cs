using NAudio.Wave;

namespace MoMoWhisper.Windows.Audio;

internal sealed class AudioCaptureStream : IDisposable
{
    private readonly IWaveIn _capture;
    private readonly WaveFileWriter _writer;
    private readonly object _gate = new();
    private readonly TaskCompletionSource<object?> _stopped =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private bool _disposed;

    public AudioCaptureStream(IWaveIn capture, string path)
    {
        _capture = capture;
        var stream = MoMoWhisper.Windows.Core.SessionFactory.OpenNewFile(path);
        try
        {
            _writer = new WaveFileWriter(stream, capture.WaveFormat);
        }
        catch
        {
            stream.Dispose();
            throw;
        }

        _capture.DataAvailable += OnDataAvailable;
        _capture.RecordingStopped += OnRecordingStopped;
    }

    public void Start()
    {
        try
        {
            _capture.StartRecording();
        }
        catch
        {
            Dispose();
            throw;
        }
    }

    public async Task StopAsync(CancellationToken cancellationToken = default)
    {
        if (_stopped.Task.IsCompleted)
        {
            await _stopped.Task.ConfigureAwait(false);
            return;
        }

        _capture.StopRecording();
        await _stopped.Task.WaitAsync(TimeSpan.FromSeconds(15), cancellationToken)
            .ConfigureAwait(false);
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs args)
    {
        lock (_gate)
        {
            if (_disposed || args.BytesRecorded <= 0)
            {
                return;
            }

            try
            {
                _writer.Write(args.Buffer, 0, args.BytesRecorded);
                _writer.Flush();
            }
            catch (Exception error)
            {
                _stopped.TrySetException(error);
                try
                {
                    _capture.StopRecording();
                }
                catch
                {
                    // Preserve the first writer error.
                }
            }
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs args)
    {
        lock (_gate)
        {
            if (!_disposed)
            {
                _writer.Dispose();
            }
        }

        if (args.Exception is not null)
        {
            _stopped.TrySetException(args.Exception);
        }
        else
        {
            _stopped.TrySetResult(null);
        }
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
            {
                return;
            }

            _disposed = true;
            _capture.DataAvailable -= OnDataAvailable;
            _capture.RecordingStopped -= OnRecordingStopped;
            _writer.Dispose();
            _capture.Dispose();
            _stopped.TrySetResult(null);
        }
    }
}
