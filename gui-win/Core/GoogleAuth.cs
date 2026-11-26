using System.Diagnostics;

namespace VertexProxy.Core;

public enum AuthState { SignedIn, ServiceAccountKey, NotSignedIn, KeyFileMissing }

public sealed record AuthStatus(AuthState State, string Detail);

/// <summary>
/// Google credentials for the node server (Application Default Credentials).
/// .env only holds connection settings; the sign-in itself lives per Windows user
/// in %APPDATA%\gcloud\application_default_credentials.json, created by
/// `gcloud auth application-default login`. A service-account key referenced by
/// GOOGLE_APPLICATION_CREDENTIALS in .env is the portable alternative.
/// </summary>
public static class GoogleAuth
{
    const string InstallerUrl = "https://dl.google.com/dl/cloudsdk/channels/rapid/GoogleCloudSDKInstaller.exe";

    // Same lookup the server (google-auth-library) does: %APPDATA% env var.
    public static string AdcPath => Path.Combine(
        Environment.GetEnvironmentVariable("APPDATA") ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "gcloud", "application_default_credentials.json");

    public static AuthStatus Check(AppPaths paths)
    {
        var key = ReadEnvValue(paths.Env, "GOOGLE_APPLICATION_CREDENTIALS");
        if (!string.IsNullOrWhiteSpace(key))
        {
            var full = Path.IsPathRooted(key) ? key : Path.GetFullPath(Path.Combine(paths.Root, key));
            return File.Exists(full)
                ? new AuthStatus(AuthState.ServiceAccountKey, full)
                : new AuthStatus(AuthState.KeyFileMissing, full);
        }
        return File.Exists(AdcPath)
            ? new AuthStatus(AuthState.SignedIn, AdcPath)
            : new AuthStatus(AuthState.NotSignedIn, AdcPath);
    }

    static string? ReadEnvValue(string envPath, string key)
    {
        if (!File.Exists(envPath)) return null;
        foreach (var raw in File.ReadAllLines(envPath))
        {
            var t = raw.Trim().TrimStart('﻿');
            if (t.StartsWith('#')) continue;
            var eq = t.IndexOf('=');
            if (eq > 0 && t[..eq].Trim() == key) return t[(eq + 1)..].Trim().Trim('"');
        }
        return null;
    }

    /// <summary>gcloud.cmd from PATH or the default per-user / machine install folders.</summary>
    public static string? FindGcloud()
    {
        var candidates = new List<string>();
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
            candidates.Add(Path.Combine(dir.Trim(), "gcloud.cmd"));
        var tail = Path.Combine("Google", "Cloud SDK", "google-cloud-sdk", "bin", "gcloud.cmd");
        // Per-user install (/singleuser). The installer uses the shell folder, not the
        // %LOCALAPPDATA% env var, so check both.
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), tail));
        if (Environment.GetEnvironmentVariable("LOCALAPPDATA") is { Length: > 0 } la) candidates.Add(Path.Combine(la, tail));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), tail));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), tail));
        foreach (var c in candidates)
        {
            try { if (File.Exists(c)) return c; } catch { }
        }
        return null;
    }

    /// <summary>
    /// Runs `gcloud auth application-default login`: it opens the browser, the user
    /// signs in there, and gcloud writes the ADC file. Then sets the quota project
    /// (avoids "quota project" warnings/403s) when a project ID is known.
    /// </summary>
    public static async Task<bool> SignInAsync(string gcloud, string? projectId, Action<string> log, CancellationToken ct)
    {
        var ok = await RunAsync(gcloud, "auth application-default login --quiet", log, ct) == 0 && File.Exists(AdcPath);
        if (ok && !string.IsNullOrWhiteSpace(projectId))
            await RunAsync(gcloud, $"auth application-default set-quota-project {projectId} --quiet", log, ct);
        return ok;
    }

    public sealed record GcpProject(string Id, string Name);

    /// <summary>
    /// Projects the signed-in account can see (Cloud Resource Manager), using an
    /// access token from the same ADC credentials the server uses.
    /// </summary>
    public static async Task<List<GcpProject>> ListProjectsAsync(string gcloud, CancellationToken ct)
    {
        var token = (await CaptureAsync(gcloud, "auth application-default print-access-token --quiet", ct)).Trim();
        if (string.IsNullOrEmpty(token) || token.Contains(' ')) throw new InvalidOperationException("Could not get an access token. Sign in first.");
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        http.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
        var list = new List<GcpProject>();
        string? page = null;
        do
        {
            var url = "https://cloudresourcemanager.googleapis.com/v1/projects?pageSize=200&filter=lifecycleState%3AACTIVE"
                      + (page != null ? "&pageToken=" + Uri.EscapeDataString(page) : "");
            using var resp = await http.GetAsync(url, ct);
            var body = await resp.Content.ReadAsStringAsync(ct);
            if (!resp.IsSuccessStatusCode) throw new InvalidOperationException($"Project list failed ({(int)resp.StatusCode}): {body[..Math.Min(200, body.Length)]}");
            using var doc = System.Text.Json.JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("projects", out var arr))
                foreach (var p in arr.EnumerateArray())
                    list.Add(new GcpProject(p.GetProperty("projectId").GetString() ?? "", p.TryGetProperty("name", out var n) ? n.GetString() ?? "" : ""));
            page = doc.RootElement.TryGetProperty("nextPageToken", out var t) ? t.GetString() : null;
        } while (!string.IsNullOrEmpty(page));
        return list.OrderBy(p => p.Name, StringComparer.OrdinalIgnoreCase).ToList();
    }

    static async Task<string> CaptureAsync(string gcloud, string args, CancellationToken ct)
    {
        var psi = new ProcessStartInfo("cmd.exe", $"/c \"\"{gcloud}\" {args}\"")
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
        };
        using var p = Process.Start(psi)!;
        var stdout = await p.StandardOutput.ReadToEndAsync(ct);
        await p.WaitForExitAsync(ct);
        return p.ExitCode == 0 ? stdout : "";
    }

    static async Task<int> RunAsync(string gcloud, string args, Action<string> log, CancellationToken ct)
    {
        log($"> gcloud {args}");
        var psi = new ProcessStartInfo("cmd.exe", $"/c \"\"{gcloud}\" {args}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        using var p = new Process { StartInfo = psi };
        p.OutputDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) log(e.Data); };
        p.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) log(e.Data); };
        p.Start();
        p.BeginOutputReadLine();
        p.BeginErrorReadLine();
        try { await p.WaitForExitAsync(ct); }
        catch (OperationCanceledException)
        {
            try { p.Kill(true); } catch { }
            throw;
        }
        return p.ExitCode;
    }

    /// <summary>
    /// Downloads Google's official Cloud CLI installer and runs it silently for the
    /// current user only (/S /singleuser: no wizard, no UAC prompt; installs under
    /// %LOCALAPPDATA%\Google\Cloud SDK, which FindGcloud checks).
    /// </summary>
    public static async Task<string?> InstallGcloudAsync(Action<string> log, CancellationToken ct)
    {
        var dir = Path.Combine(Path.GetTempPath(), "VertexOpenAIProxy-gcloud");
        Directory.CreateDirectory(dir);
        var exe = Path.Combine(dir, "GoogleCloudSDKInstaller.exe");
        log("Downloading Google Cloud CLI...");
        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) })
        await using (var src = await http.GetStreamAsync(InstallerUrl, ct))
        await using (var dst = File.Create(exe))
            await src.CopyToAsync(dst, ct);
        log("Installing Google Cloud CLI (a few minutes)...");
        using var p = Process.Start(new ProcessStartInfo(exe, "/S /singleuser /noreporting /nostartmenu /nodesktop")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
        })!;
        await p.WaitForExitAsync(ct);
        // The NSIS bootstrapper can return before its component install finishes; wait for gcloud.cmd.
        for (var i = 0; i < 600 && FindGcloud() == null; i++) await Task.Delay(1000, ct);
        var g = FindGcloud();
        log(g != null ? "Google Cloud CLI installed." : "Google Cloud CLI install did not finish.");
        return g;
    }
}
