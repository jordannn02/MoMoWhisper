using MoMoWhisper.Windows.Core;
using NAudio.Wave;

namespace MoMoWhisper.Windows.Audio;

internal static class AudioNormalizer
{
    private static readonly WaveFormat WhisperWaveFormat = new(16_000, 16, 1);

    public static Task<string> NormalizeAsync(
        string capturePath,
        string destinationPath,
        CancellationToken cancellationToken = default) =>
        Task.Run(() => Normalize(capturePath, destinationPath, cancellationToken), cancellationToken);

    private static string Normalize(
        string capturePath,
        string destinationPath,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(capturePath) || new FileInfo(capturePath).Length <= 44)
        {
            throw new InvalidDataException($"Captured WAV is empty or header-only: {capturePath}");
        }

        if (File.Exists(destinationPath))
        {
            throw new IOException($"Refusing to overwrite an existing normalized WAV: {destinationPath}");
        }

        try
        {
            using (var reader = new AudioFileReader(capturePath))
            using (var resampler = new MediaFoundationResampler(reader, WhisperWaveFormat)
                   {
                       ResamplerQuality = 60
                   })
            using (var destination = SessionFactory.OpenNewFile(destinationPath))
            using (var writer = new WaveFileWriter(destination, WhisperWaveFormat))
            {
                var buffer = new byte[WhisperWaveFormat.AverageBytesPerSecond];
                int bytesRead;
                while ((bytesRead = resampler.Read(buffer, 0, buffer.Length)) > 0)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    writer.Write(buffer, 0, bytesRead);
                }

                writer.Flush();
            }

            if (new FileInfo(destinationPath).Length <= 44)
            {
                throw new InvalidDataException($"Normalized WAV is empty: {destinationPath}");
            }

            File.Delete(capturePath);
            return destinationPath;
        }
        catch
        {
            if (File.Exists(destinationPath))
            {
                File.Delete(destinationPath);
            }

            throw;
        }
    }
}
