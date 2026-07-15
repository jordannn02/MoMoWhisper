using System.Text;

namespace MoMoWhisper.Windows.Core;

public sealed class SessionFactory
{
    private readonly AppPaths _paths;
    private readonly Func<DateTimeOffset> _clock;
    private readonly Func<Guid> _idFactory;

    public SessionFactory(
        AppPaths paths,
        Func<DateTimeOffset>? clock = null,
        Func<Guid>? idFactory = null)
    {
        _paths = paths;
        _clock = clock ?? (() => DateTimeOffset.Now);
        _idFactory = idFactory ?? Guid.NewGuid;
    }

    public MeetingSessionMetadata CreateSession(string? requestedTitle)
    {
        _paths.EnsureCreated();
        var now = _clock();
        var title = string.IsNullOrWhiteSpace(requestedTitle)
            ? $"Meeting {now:yyyy-MM-dd HH:mm:ss}"
            : requestedTitle.Trim();

        for (var attempt = 0; attempt < 32; attempt++)
        {
            var id = _idFactory();
            var folderName = $"{now:yyyyMMdd_HHmmssfff}_{SafePathComponent(title)}_{id:N}";
            var directory = Path.Combine(_paths.MeetingsDirectory, folderName);
            if (Directory.Exists(directory))
            {
                continue;
            }

            Directory.CreateDirectory(directory);
            using (OpenNewFile(Path.Combine(directory, ".session-lock")))
            {
            }

            Directory.CreateDirectory(Path.Combine(directory, "recordings"));
            return new MeetingSessionMetadata
            {
                SessionId = id,
                Title = title,
                StartedAt = now,
                SessionDirectory = directory,
                Status = "ready"
            };
        }

        throw new IOException("Unable to allocate a unique meeting session directory.");
    }

    public RecordingPartMetadata CreateRecordingPart(
        MeetingSessionMetadata session,
        int sequence,
        bool includeMicrophone,
        bool includeSystemAudio)
    {
        if (!includeMicrophone && !includeSystemAudio)
        {
            throw new ArgumentException("At least one audio source must be selected.");
        }

        if (sequence < 1)
        {
            throw new ArgumentOutOfRangeException(nameof(sequence));
        }

        var recordingsDirectory = Path.Combine(session.SessionDirectory, "recordings");
        Directory.CreateDirectory(recordingsDirectory);
        var stem = $"part-{sequence:000}";
        var microphonePath = includeMicrophone
            ? Path.Combine(recordingsDirectory, $"{stem}-mic.wav")
            : null;
        var systemPath = includeSystemAudio
            ? Path.Combine(recordingsDirectory, $"{stem}-sys.wav")
            : null;

        EnsureAvailable(microphonePath);
        EnsureAvailable(systemPath);
        EnsureAvailable(CapturePathFor(microphonePath));
        EnsureAvailable(CapturePathFor(systemPath));

        return new RecordingPartMetadata
        {
            Sequence = sequence,
            StartedAt = _clock(),
            Status = "ready",
            MicrophonePath = microphonePath,
            SystemAudioPath = systemPath,
            MicrophoneRequested = includeMicrophone,
            SystemAudioRequested = includeSystemAudio,
            MicrophoneTranscriptionStatus = includeMicrophone ? "pending" : "not-requested",
            SystemAudioTranscriptionStatus = includeSystemAudio ? "pending" : "not-requested"
        };
    }

    public static string? CapturePathFor(string? finalPath)
    {
        if (finalPath is null)
        {
            return null;
        }

        var directory = Path.GetDirectoryName(finalPath)
            ?? throw new ArgumentException("The recording path has no directory.", nameof(finalPath));
        return Path.Combine(
            directory,
            $"{Path.GetFileNameWithoutExtension(finalPath)}.capture.wav");
    }

    public static FileStream OpenNewFile(string path)
    {
        var parent = Path.GetDirectoryName(path)
            ?? throw new ArgumentException("The output path has no directory.", nameof(path));
        Directory.CreateDirectory(parent);
        return new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
    }

    public static string SafePathComponent(string value)
    {
        var invalid = Path.GetInvalidFileNameChars().ToHashSet();
        var builder = new StringBuilder(value.Length);
        foreach (var character in value.Trim())
        {
            builder.Append(invalid.Contains(character) || char.IsControl(character) ? '-' : character);
        }

        var result = builder.ToString().Trim(' ', '.');
        if (string.IsNullOrWhiteSpace(result))
        {
            result = "Meeting";
        }

        return result.Length <= 48 ? result : result[..48].TrimEnd();
    }

    private static void EnsureAvailable(string? path)
    {
        if (path is not null && File.Exists(path))
        {
            throw new IOException($"Refusing to overwrite an existing recording path: {path}");
        }
    }
}
