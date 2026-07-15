namespace MoMoWhisper.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 1
            && string.Equals(args[0], "--smoke-test", StringComparison.Ordinal))
        {
            _ = typeof(NAudio.CoreAudioApi.WasapiCapture);
            _ = typeof(MoMoWhisper.Windows.Core.WhisperRuntime);
            return 0;
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
        return 0;
    }
}
