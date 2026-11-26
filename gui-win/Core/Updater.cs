using System.Diagnostics;
using System.IO.Compression;
using System.Reflection;
using System.Text.Json;

namespace VertexProxy.Core;

public sealed record ReleaseInfo(string Version, string Tag, string ZipUrl);

/// <summary>
/// Auto-update from this repo's GitHub releases (tags windows-vX.Y[.Z], newest
/// non-draft non-prerelease with a .zip asset). Same release layout and same
/// apply strategy as the Rust GUI: a hidden helper waits for this process to exit,
/// robocopies the new files over the install folder (keeping .env and settings)
/// and relaunches.
/// </summary>
public static class Updater
{
    public const string Repo = "designloves2/vertex-openai-proxy";
    const string TagPrefix = "windows-v";
    static readonly string[] Keep = { ".env", ".gui-rs-settings" };
    const string ExeName = "VertexOpenAIProxy.exe";

    public static string CurrentVersion
    {
        get
        {
            var v = Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 0, 0);
            return $"{v.Major}.{v.Minor}.{Math.Max(0, v.Build)}";
        }
    }

    static Version Parse(string s)
    {
        var parts = s.TrimStart('v').Split('.', '-').Select(p => int.TryParse(p, out var n) ? n : -1).TakeWhile(n => n >= 0).ToList();
        while (parts.Count < 3) parts.Add(0);
        return new Version(parts[0], parts[1], parts[2]);
    }

    public static bool IsNewer(string candidate, string current) => Parse(candidate) > Parse(current);

    static HttpClient NewClient()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromMinutes(10) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd($"VertexOpenAIProxy-updater/{CurrentVersion}");
        c.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return c;
    }

    public static async Task<ReleaseInfo?> CheckAsync()
    {
        using var http = NewClient();
        using var doc = JsonDocument.Parse(await http.GetStringAsync($"https://api.github.com/repos/{Repo}/releases?per_page=30"));
        ReleaseInfo? best = null;
        foreach (var r in doc.RootElement.EnumerateArray())
        {
            if (r.GetProperty("draft").GetBoolean() || r.GetProperty("prerelease").GetBoolean()) continue;
            var tag = r.GetProperty("tag_name").GetString() ?? "";
            if (!tag.StartsWith(TagPrefix)) continue;
            var ver = tag[TagPrefix.Length..];
            var zip = r.GetProperty("assets").EnumerateArray()
                .Select(a => a.GetProperty("browser_download_url").GetString() ?? "")
                .FirstOrDefault(u => u.EndsWith(".zip", StringComparison.OrdinalIgnoreCase));
            if (zip == null || !IsNewer(ver, CurrentVersion)) continue;
            if (best == null || IsNewer(ver, best.Version)) best = new ReleaseInfo(ver, tag, zip);
        }
        return best;
    }

    /// <summary>Only a release install (exe directly next to index.js) may self-update.</summary>
    public static string? NotUpdatableReason(AppPaths paths)
    {
        var exeDir = Path.GetDirectoryName(Environment.ProcessPath) ?? "";
        return string.Equals(Path.GetFullPath(exeDir).TrimEnd('\\'), Path.GetFullPath(paths.Root).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase) && paths.HasServer
            ? null
            : "This is a development build (the exe is not next to index.js). Update it with git and build-release.ps1 instead.";
    }

    static string? FindPayload(string dir, int depth)
    {
        if (File.Exists(Path.Combine(dir, "index.js")) && File.Exists(Path.Combine(dir, ExeName))) return dir;
        if (depth == 0) return null;
        foreach (var d in Directory.GetDirectories(dir))
            if (FindPayload(d, depth - 1) is { } p) return p;
        return null;
    }

    public static async Task<string> DownloadAsync(ReleaseInfo rel, IProgress<double>? progress = null)
    {
        var work = Path.Combine(Path.GetTempPath(), $"VertexOpenAIProxy-update-{rel.Version}");
        if (Directory.Exists(work)) Directory.Delete(work, true);
        var extract = Path.Combine(work, "x");
        Directory.CreateDirectory(extract);
        var zipPath = Path.Combine(work, "release.zip");

        using (var http = NewClient())
        using (var resp = await http.GetAsync(rel.ZipUrl, HttpCompletionOption.ResponseHeadersRead))
        {
            resp.EnsureSuccessStatusCode();
            var total = resp.Content.Headers.ContentLength ?? 0;
            await using var src = await resp.Content.ReadAsStreamAsync();
            await using var dst = File.Create(zipPath);
            var buf = new byte[81920];
            long done = 0;
            int n;
            while ((n = await src.ReadAsync(buf)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n));
                done += n;
                if (total > 0) progress?.Report((double)done / total);
            }
        }
        ZipFile.ExtractToDirectory(zipPath, extract);
        return FindPayload(extract, 2) ?? throw new InvalidOperationException($"The release zip does not contain {ExeName} + index.js.");
    }

    /// <summary>Starts the hidden helper; the caller must exit right after.</summary>
    public static void Apply(string payload, AppPaths paths)
    {
        var exe = Environment.ProcessPath!;
        var exeName = Path.GetFileName(exe);
        if (!exeName.Equals(ExeName, StringComparison.OrdinalIgnoreCase))
            File.Move(Path.Combine(payload, ExeName), Path.Combine(payload, exeName), true);
        var pid = Environment.ProcessId;
        var work = Directory.GetParent(payload)?.Parent?.FullName ?? payload;
        var log = Path.Combine(paths.Root, "update.log");
        var script = Path.Combine(work, "apply-update.cmd");
        // `timeout` fails without a console, so delays use ping.
        var body =
            "@echo off\r\n" +
            ":wait\r\n" +
            $"tasklist /FI \"PID eq {pid}\" /NH | find \" {pid} \" >nul && (ping -n 2 127.0.0.1 >nul & goto wait)\r\n" +
            "set n=0\r\n" +
            ":copy\r\n" +
            $"robocopy \"{payload}\" \"{paths.Root}\" /E /R:5 /W:1 /XF {string.Join(' ', Keep)} /NP /NDL > \"{log}\"\r\n" +
            "if not errorlevel 8 goto done\r\n" +
            "set /a n+=1\r\n" +
            "if %n% GEQ 5 goto done\r\n" +
            "ping -n 3 127.0.0.1 >nul\r\n" +
            "goto copy\r\n" +
            ":done\r\n" +
            $"start \"\" \"{Path.Combine(paths.Root, exeName)}\"\r\n";
        File.WriteAllText(script, body);
        Process.Start(new ProcessStartInfo("cmd.exe", $"/c \"{script}\"")
        {
            WorkingDirectory = work,
            CreateNoWindow = true,
            UseShellExecute = false,
        });
    }
}
