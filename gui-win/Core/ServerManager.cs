using System.Diagnostics;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Text.Json;

namespace VertexProxy.Core;

/// <summary>Starts/stops the node proxy (index.js) and streams its output.</summary>
public sealed class ServerManager
{
    readonly AppPaths _paths;
    Process? _proc;
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };

    public event Action<string, bool>? Output;   // line, isError
    public event Action<bool>? StateChanged;      // running

    public ServerManager(AppPaths paths) => _paths = paths;

    public bool IsRunning => _proc is { HasExited: false };

    public static bool PortInUse(string port)
    {
        if (!int.TryParse(port, out var p)) return false;
        try
        {
            using var c = new TcpClient();
            return c.ConnectAsync("127.0.0.1", p).Wait(200) && c.Connected;
        }
        catch { return false; }
    }

    string? FindNode()
    {
        // A bundled runtime (release folder) wins over anything on PATH.
        foreach (var b in new[] { Path.Combine(_paths.Root, "node", "node.exe"), Path.Combine(_paths.Root, "node.exe") })
            if (File.Exists(b)) return b;
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
        {
            try
            {
                var p = Path.Combine(dir.Trim(), "node.exe");
                if (File.Exists(p)) return p;
            }
            catch { }
        }
        return null;
    }

    public bool Start(string port)
    {
        if (IsRunning) return true;
        if (!_paths.HasServer) { Output?.Invoke($"index.js not found (looked upward from {AppContext.BaseDirectory}).", true); return false; }
        if (PortInUse(port))
        {
            Output?.Invoke($"Port {port} is already in use (another proxy or app). Stop it or change the port.", true);
            return false;
        }
        var node = FindNode();
        if (node == null) { Output?.Invoke("node.exe not found. Install Node.js or use the release build with bundled node.", true); return false; }

        var psi = new ProcessStartInfo(node, "index.js")
        {
            WorkingDirectory = _paths.Root,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = System.Text.Encoding.UTF8,
            StandardErrorEncoding = System.Text.Encoding.UTF8,
        };
        psi.Environment["FORCE_COLOR"] = "0";
        var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
        p.OutputDataReceived += (_, e) => { if (e.Data != null) Output?.Invoke(e.Data, false); };
        p.ErrorDataReceived += (_, e) => { if (e.Data != null) Output?.Invoke(e.Data, true); };
        p.Exited += (_, _) => { if (_proc == p) { Output?.Invoke("Server process exited.", true); StateChanged?.Invoke(false); } };
        try { p.Start(); }
        catch (Exception ex) { Output?.Invoke("Failed to start node: " + ex.Message, true); return false; }
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        _proc = p;
        StateChanged?.Invoke(true);
        return true;
    }

    public async Task StopAsync(string port)
    {
        var p = _proc;
        _proc = null;
        if (p is { HasExited: false })
        {
            try { p.Kill(entireProcessTree: true); } catch { }
            try { await p.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)); } catch { }
        }
        // Wait for the port to really clear; a fixed sleep caused EADDRINUSE on restart.
        for (var i = 0; i < 40 && PortInUse(port); i++) await Task.Delay(150);
        StateChanged?.Invoke(false);
    }

    /// <summary>Chat model ids from the running server's live Vertex catalog.</summary>
    public static async Task<List<string>> FetchChatModelsAsync(string port)
    {
        using var doc = JsonDocument.Parse(await Http.GetStringAsync($"http://127.0.0.1:{port}/v1/models?type=chat"));
        return doc.RootElement.GetProperty("data").EnumerateArray()
            .Select(m => m.GetProperty("id").GetString() ?? "")
            .Where(id => id.StartsWith("gemini") || id.StartsWith("gemma"))
            .ToList();
    }
}
