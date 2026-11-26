using Microsoft.Win32;

namespace VertexProxy.Core;

/// <summary>"Start with Windows" (HKCU Run) and "auto-start server" (.gui-rs-settings).</summary>
public sealed class AppOptions
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunName = "VertexOpenAIProxyGui"; // same value the Rust GUI used, so it is replaced, not duplicated
    readonly AppPaths _paths;

    public AppOptions(AppPaths paths) => _paths = paths;

    public bool StartWithWindows
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(RunName) is string;
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue(RunName, $"\"{Environment.ProcessPath}\" --minimized");
            else k.DeleteValue(RunName, false);
        }
    }

    /// <summary>
    /// If the startup entry points at another exe (e.g. the old Rust GUI), repoint it
    /// at this one. Only for release installs, so a dev build never hijacks it.
    /// </summary>
    public void RepointStartupEntry()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKey);
        if (k?.GetValue(RunName) is not string v) return;
        if (v.Contains(Environment.ProcessPath ?? "\0", StringComparison.OrdinalIgnoreCase)) return;
        if (Updater.NotUpdatableReason(_paths) != null) return;
        StartWithWindows = true;
    }

    public bool AutoStartServer
    {
        get => ReadFlag("auto_start_server");
        set => WriteFlag("auto_start_server", value);
    }

    public bool AutoCheckUpdates
    {
        get => !File.Exists(_paths.Settings) || !File.ReadAllText(_paths.Settings).Contains("auto_check_updates=0");
        set => WriteFlag("auto_check_updates", value);
    }

    bool ReadFlag(string key) =>
        File.Exists(_paths.Settings) && File.ReadAllText(_paths.Settings).Contains($"{key}=1");

    void WriteFlag(string key, bool on)
    {
        var lines = File.Exists(_paths.Settings)
            ? File.ReadAllLines(_paths.Settings).Where(l => !l.StartsWith(key + "=")).ToList()
            : new List<string>();
        lines.Add($"{key}={(on ? 1 : 0)}");
        File.WriteAllLines(_paths.Settings, lines);
    }
}
