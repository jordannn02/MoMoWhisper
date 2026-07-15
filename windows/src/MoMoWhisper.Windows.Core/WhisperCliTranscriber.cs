using System.Diagnostics;

namespace MoMoWhisper.Windows.Core;

public sealed record WhisperRuntime(string ExecutablePath, string ModelPath)
{
    public static WhisperRuntime FromApplicationDirectory(string applicationDirectory) => new(
        Path.Combine(applicationDirectory, "tools", "whisper", "whisper-cli.exe"),
        Path.Combine(applicationDirectory, "models", "ggml-base.bin"));

    public bool IsAvailable => File.Exists(ExecutablePath) && File.Exists(ModelPath);

    public string AvailabilityText => IsAvailable
        ? "bundled whisper.cpp + multilingual base model ready"
        : $"missing bundled runtime: CLI={File.Exists(ExecutablePath)}, model={File.Exists(ModelPath)}";

    public void EnsureAvailable()
    {
        if (!File.Exists(ExecutablePath))
        {
            throw new FileNotFoundException("Bundled whisper.cpp CLI is missing.", ExecutablePath);
        }

        if (!File.Exists(ModelPath))
        {
            throw new FileNotFoundException("Bundled multilingual base model is missing.", ModelPath);
        }
    }
}

public sealed class WhisperCliTranscriber
{
    private readonly WhisperRuntime _runtime;

    public WhisperCliTranscriber(WhisperRuntime runtime)
    {
        _runtime = runtime;
    }

    public async Task<IReadOnlyList<TranscriptSegment>> TranscribeAsync(
        string audioPath,
        TranscriptSource source,
        long timelineOffsetMilliseconds = 0,
        CancellationToken cancellationToken = default)
    {
        _runtime.EnsureAvailable();
        if (!File.Exists(audioPath))
        {
            throw new FileNotFoundException("Recording file is missing.", audioPath);
        }

        var outputBase = Path.Combine(
            Path.GetDirectoryName(audioPath)!,
            $"{Path.GetFileNameWithoutExtension(audioPath)}.whisper-{Guid.NewGuid():N}");
        var outputJson = $"{outputBase}.json";
        IReadOnlyList<TranscriptSegment>? parsedSegments = null;
        Exception? cleanupError = null;
        var parsedSuccessfully = false;

        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = _runtime.ExecutablePath,
                WorkingDirectory = Path.GetDirectoryName(_runtime.ExecutablePath)!,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                CreateNoWindow = true
            };
            startInfo.ArgumentList.Add("-m");
            startInfo.ArgumentList.Add(_runtime.ModelPath);
            startInfo.ArgumentList.Add("-f");
            startInfo.ArgumentList.Add(audioPath);
            startInfo.ArgumentList.Add("-l");
            startInfo.ArgumentList.Add("auto");
            startInfo.ArgumentList.Add("-oj");
            startInfo.ArgumentList.Add("-of");
            startInfo.ArgumentList.Add(outputBase);
            startInfo.ArgumentList.Add("-ng");
            startInfo.ArgumentList.Add("-t");
            startInfo.ArgumentList.Add(Math.Clamp(Environment.ProcessorCount / 2, 1, 8).ToString());

            using var process = Process.Start(startInfo)
                ?? throw new InvalidOperationException("Failed to launch bundled whisper.cpp.");
            var stdoutTask = process.StandardOutput.ReadToEndAsync();
            var stderrTask = process.StandardError.ReadToEndAsync();
            try
            {
                await process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                if (!process.HasExited)
                {
                    try
                    {
                        process.Kill(entireProcessTree: true);
                    }
                    catch (InvalidOperationException)
                    {
                        // The process exited between HasExited and Kill.
                    }
                }

                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
                throw;
            }
            var stdout = await stdoutTask.ConfigureAwait(false);
            var stderr = await stderrTask.ConfigureAwait(false);

            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException(
                    $"whisper.cpp exited with code {process.ExitCode}: {TrimDiagnostic(stderr, stdout)}");
            }

            if (!File.Exists(outputJson))
            {
                throw new InvalidDataException(
                    $"whisper.cpp did not create the expected JSON output: {outputJson}");
            }

            parsedSegments = WhisperJsonParser.Parse(
                await File.ReadAllTextAsync(outputJson, cancellationToken).ConfigureAwait(false),
                source,
                timelineOffsetMilliseconds);
            parsedSuccessfully = true;
        }
        catch (OperationCanceledException error)
        {
            throw new OperationCanceledException(
                $"Post-stop transcription was cancelled. Diagnostic JSON, if produced, was kept at: {outputJson}",
                error,
                cancellationToken);
        }
        catch (Exception error)
        {
            throw new InvalidDataException(
                $"Transcription failed. Diagnostic JSON, if produced, was kept at: {outputJson}. {error.Message}",
                error);
        }
        finally
        {
            if (parsedSuccessfully && File.Exists(outputJson))
            {
                try
                {
                    File.Delete(outputJson);
                }
                catch (Exception error)
                {
                    cleanupError = error;
                }
            }
        }

        if (cleanupError is not null)
        {
            throw new IOException(
                $"Transcription succeeded, but its temporary JSON could not be removed and was kept at: {outputJson}",
                cleanupError);
        }

        return parsedSegments
            ?? throw new InvalidDataException("whisper.cpp completed without a parsed transcription result.");
    }

    private static string TrimDiagnostic(params string[] values)
    {
        var value = string.Join(" | ", values.Where(item => !string.IsNullOrWhiteSpace(item))).Trim();
        return value.Length <= 800 ? value : value[..800];
    }
}
