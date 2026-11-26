using Microsoft.UI.Xaml;
using VertexProxy.Core;

namespace VertexProxy;

public partial class App : Application
{
    static Mutex? _instanceMutex;
    MainWindow? _window;

    public App()
    {
        InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var paths = new AppPaths();
        _instanceMutex = new Mutex(true, @"Local\VertexOpenAIProxyGuiWinUI", out var created);
        if (!created)
        {
            // Already running: ask that instance to show its window, then leave.
            try { File.WriteAllText(paths.Command, "open"); } catch { }
            _instanceMutex.Dispose();
            _instanceMutex = null;
            Exit();
            return;
        }
        var minimized = Environment.GetCommandLineArgs().Any(a => a.Equals("--minimized", StringComparison.OrdinalIgnoreCase));
        _window = new MainWindow(paths, minimized);
    }
}
