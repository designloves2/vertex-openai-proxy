namespace VertexProxy.Core;

/// <summary>
/// Locations shared with the server and the older GUIs. The project root is the
/// nearest ancestor of the exe that contains index.js (release folder, or the repo
/// when running a dev build from gui-win\bin\...).
/// </summary>
public sealed class AppPaths
{
    public string Root { get; }
    public string Env => Path.Combine(Root, ".env");
    /// <summary>Polled command file ("open" / "restart" / "quit"), same as the Rust GUI.</summary>
    public string Command => Path.Combine(Root, ".gui-command");
    /// <summary>Kept under the Rust GUI's name so existing installs keep their settings.</summary>
    public string Settings => Path.Combine(Root, ".gui-rs-settings");

    public AppPaths()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null && !File.Exists(Path.Combine(dir.FullName, "index.js")))
            dir = dir.Parent;
        Root = dir?.FullName ?? Environment.CurrentDirectory;
    }

    public bool HasServer => File.Exists(Path.Combine(Root, "index.js"));
}
