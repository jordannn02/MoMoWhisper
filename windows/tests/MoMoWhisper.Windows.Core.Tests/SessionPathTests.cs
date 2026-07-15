using System.Text;
using MoMoWhisper.Windows.Core;

namespace MoMoWhisper.Windows.Core.Tests;

public sealed class SessionPathTests
{
    [Fact]
    public void ConsecutiveSessionsAndPartsReceiveDifferentPaths()
    {
        using var temporary = new TemporaryDirectory();
        var paths = new AppPaths(
            temporary.Path,
            System.IO.Path.Combine(temporary.Path, "Meetings"),
            System.IO.Path.Combine(temporary.Path, "Handoff"));
        var ids = new Queue<Guid>(
        [
            Guid.Parse("11111111-1111-1111-1111-111111111111"),
            Guid.Parse("22222222-2222-2222-2222-222222222222")
        ]);
        var factory = new SessionFactory(
            paths,
            () => new DateTimeOffset(2026, 7, 15, 9, 30, 0, TimeSpan.Zero),
            () => ids.Dequeue());

        var first = factory.CreateSession("Same title");
        var second = factory.CreateSession("Same title");
        var firstPart = factory.CreateRecordingPart(first, 1, true, true);
        var resumedPart = factory.CreateRecordingPart(first, 2, true, true);
        var secondPart = factory.CreateRecordingPart(second, 1, true, true);

        Assert.NotEqual(first.SessionDirectory, second.SessionDirectory);
        Assert.NotEqual(firstPart.MicrophonePath, secondPart.MicrophonePath);
        Assert.NotEqual(firstPart.SystemAudioPath, secondPart.SystemAudioPath);
        Assert.NotEqual(firstPart.MicrophonePath, resumedPart.MicrophonePath);
        Assert.NotEqual(firstPart.SystemAudioPath, resumedPart.SystemAudioPath);
        Assert.EndsWith("part-001-mic.wav", firstPart.MicrophonePath!, StringComparison.OrdinalIgnoreCase);
        Assert.EndsWith("part-001-sys.wav", firstPart.SystemAudioPath!, StringComparison.OrdinalIgnoreCase);
        Assert.EndsWith("part-002-mic.wav", resumedPart.MicrophonePath!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void OpenNewFileRefusesToOverwriteExistingAudio()
    {
        using var temporary = new TemporaryDirectory();
        var path = System.IO.Path.Combine(temporary.Path, "recording.wav");
        var expected = Encoding.UTF8.GetBytes("existing recording must survive");
        File.WriteAllBytes(path, expected);

        Assert.Throws<IOException>(() => SessionFactory.OpenNewFile(path));
        Assert.Equal(expected, File.ReadAllBytes(path));
    }

    [Fact]
    public void ExistingPartPathIsRejectedBeforeCaptureStarts()
    {
        using var temporary = new TemporaryDirectory();
        var paths = new AppPaths(
            temporary.Path,
            System.IO.Path.Combine(temporary.Path, "Meetings"),
            System.IO.Path.Combine(temporary.Path, "Handoff"));
        var factory = new SessionFactory(paths);
        var session = factory.CreateSession("collision test");
        var recordings = System.IO.Path.Combine(session.SessionDirectory, "recordings");
        File.WriteAllText(System.IO.Path.Combine(recordings, "part-001-mic.wav"), "keep");

        Assert.Throws<IOException>(() =>
            factory.CreateRecordingPart(session, 1, includeMicrophone: true, includeSystemAudio: false));
        Assert.Equal("keep", File.ReadAllText(System.IO.Path.Combine(recordings, "part-001-mic.wav")));
    }
}
