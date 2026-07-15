using System.Text.Json;
using System.Text.Json.Serialization;

namespace MoMoWhisper.Windows.Core;

public static class MetadataStore
{
    public static JsonSerializerOptions JsonOptions { get; } = CreateOptions();

    public static string MetadataPath(MeetingSessionMetadata metadata) =>
        Path.Combine(metadata.SessionDirectory, "metadata.json");

    public static void Write(MeetingSessionMetadata metadata) =>
        AtomicFile.WriteAllText(
            MetadataPath(metadata),
            JsonSerializer.Serialize(metadata, JsonOptions));

    public static MeetingSessionMetadata Read(string path)
    {
        var value = JsonSerializer.Deserialize<MeetingSessionMetadata>(
            File.ReadAllText(path),
            JsonOptions);
        return value ?? throw new InvalidDataException($"Metadata is empty: {path}");
    }

    private static JsonSerializerOptions CreateOptions()
    {
        var options = new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = true
        };
        options.Converters.Add(new JsonStringEnumConverter(JsonNamingPolicy.CamelCase));
        return options;
    }
}

public static class AtomicFile
{
    public static void WriteAllText(string path, string content)
    {
        var directory = Path.GetDirectoryName(path)
            ?? throw new ArgumentException("The output path has no directory.", nameof(path));
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");

        try
        {
            File.WriteAllText(temporaryPath, content, new System.Text.UTF8Encoding(false));
            File.Move(temporaryPath, path, true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}
