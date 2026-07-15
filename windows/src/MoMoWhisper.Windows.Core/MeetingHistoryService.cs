using System.Text.Json;

namespace MoMoWhisper.Windows.Core;

public sealed class MeetingHistoryService
{
    private readonly AppPaths _paths;

    public MeetingHistoryService(AppPaths paths)
    {
        _paths = paths;
    }

    public IReadOnlyList<MeetingSessionMetadata> ListSessions()
    {
        _paths.EnsureCreated();
        var sessions = new List<MeetingSessionMetadata>();
        foreach (var metadataPath in Directory.EnumerateFiles(
                     _paths.MeetingsDirectory,
                     "metadata.json",
                     SearchOption.AllDirectories))
        {
            try
            {
                sessions.Add(MetadataStore.Read(metadataPath));
            }
            catch (IOException)
            {
                // A concurrently written or damaged session is skipped in the history UI.
            }
            catch (JsonException)
            {
                // Corrupt metadata remains on disk for manual recovery; history stays usable.
            }
        }

        return sessions
            .OrderByDescending(item => item.StartedAt)
            .ToArray();
    }
}
