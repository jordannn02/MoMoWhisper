namespace MoMoWhisper.Windows.Core.Tests;

internal sealed class TemporaryDirectory : IDisposable
{
    public TemporaryDirectory()
    {
        Path = System.IO.Path.Combine(
            System.IO.Path.GetTempPath(),
            $"MoMoWhisper-Windows-Tests-{Guid.NewGuid():N}");
        Directory.CreateDirectory(Path);
    }

    public string Path { get; }

    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (IOException)
        {
            // Test cleanup must not mask the assertion result.
        }
        catch (UnauthorizedAccessException)
        {
            // Test cleanup must not mask the assertion result.
        }
    }
}
