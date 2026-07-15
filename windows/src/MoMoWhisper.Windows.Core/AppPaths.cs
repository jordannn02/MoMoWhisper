namespace MoMoWhisper.Windows.Core;

public sealed record AppPaths(
    string RootDirectory,
    string MeetingsDirectory,
    string HandoffDirectory)
{
    public static AppPaths CreateDefault()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new InvalidOperationException("Windows LocalApplicationData is unavailable.");
        }

        var root = Path.Combine(localAppData, "MoMoWhisper", "WindowsBeta");
        return new AppPaths(
            root,
            Path.Combine(root, "Meetings"),
            Path.Combine(root, "CodexHandoff"));
    }

    public void EnsureCreated()
    {
        Directory.CreateDirectory(RootDirectory);
        Directory.CreateDirectory(MeetingsDirectory);
        Directory.CreateDirectory(HandoffDirectory);
    }
}
