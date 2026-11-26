using System.Text;

namespace VertexProxy.Core;

public sealed record ProxySettings(string ProjectId, string Location, string Model, string Port);

/// <summary>
/// Reads/writes only the managed keys of .env and leaves every other line alone.
/// .env must be written WITHOUT a BOM (dotenv would read the BOM into the first key).
/// </summary>
public static class EnvFile
{
    static readonly string[] Keys = { "GOOGLE_CLOUD_PROJECT_ID", "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_MODEL_ID", "PORT" };

    public static ProxySettings Read(string path)
    {
        var v = new[] { "", "global", "gemini-3.7-flash", "3000" };
        if (File.Exists(path))
        {
            foreach (var raw in File.ReadAllLines(path))
            {
                var t = raw.Trim().TrimStart('﻿');
                if (t.Length == 0 || t.StartsWith('#')) continue;
                var eq = t.IndexOf('=');
                if (eq < 0) continue;
                var i = Array.IndexOf(Keys, t[..eq].Trim());
                if (i >= 0) v[i] = t[(eq + 1)..].Trim();
            }
        }
        return new ProxySettings(v[0], v[1], v[2], v[3]);
    }

    public static void Write(string path, ProxySettings s)
    {
        var values = new[] { s.ProjectId, s.Location, s.Model, s.Port };
        var seen = new bool[Keys.Length];
        var lines = new List<string>();
        if (File.Exists(path))
        {
            foreach (var raw in File.ReadAllLines(path))
            {
                var t = raw.TrimEnd().TrimStart('﻿');
                var eq = t.IndexOf('=');
                var i = eq > 0 ? Array.IndexOf(Keys, t[..eq].Trim()) : -1;
                if (i < 0) { lines.Add(t); continue; }
                if (seen[i]) continue;
                seen[i] = true;
                lines.Add($"{Keys[i]}={values[i]}");
            }
        }
        for (var i = 0; i < Keys.Length; i++)
            if (!seen[i]) lines.Add($"{Keys[i]}={values[i]}");
        File.WriteAllText(path, string.Join("\r\n", lines) + "\r\n", new UTF8Encoding(false));
    }
}
