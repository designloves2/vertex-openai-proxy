# Vertex OpenAI Proxy — GUI debugging history

## Status: root cause found and fixed (needs a real-world confirmation run)

The Windows GUI (`gui/VertexProxyGui.ps1`) failed to launch: double-clicking
`vertex-openai-proxy-GUI-run.bat` showed a console window that opened and
closed almost instantly, no GUI window ever appeared, and `gui\crash.log`
was never created.

### Root cause
`gui/VertexProxyGui.ps1` was saved as UTF-8 **without a BOM**, and it
contained Korean UI strings. Windows PowerShell 5.1 (`powershell.exe`, not
`pwsh.exe`) does not assume UTF-8 for a BOM-less script — it falls back to
the system's legacy codepage (e.g. CP949 on a Korean Windows install). That
misreads the Korean multi-byte sequences as garbage bytes, one of which
happened to decode as a literal `'` (single quote), which prematurely closed
a string and cascaded into a chain of parse errors throughout the rest of
the file — e.g. `Unexpected token 'Collapsed"` and `Missing closing '}'`
several hundred lines away from the actual problem.

Critically, this is a **parse-time** failure: it happens before the script
body executes a single statement, so no in-script error handling (the
`trap` block, `Write-CrashLog`) can ever catch it — explaining why
`crash.log` was never written no matter how early that logic was moved.

This is the exact same class of bug this repo hit earlier with
`install-windows.ps1` and with `.env` (see below) — Windows PowerShell 5.1
+ non-ASCII text + missing/wrong BOM is a recurring trap in this codebase.

### Fix applied
Two changes, both committed:
1. Added a UTF-8 BOM to `gui/VertexProxyGui.ps1` (byte-level fix, makes
   PowerShell 5.1 correctly detect UTF-8 regardless of content).
2. **Translated all UI strings, message boxes, and log lines in
   `gui/VertexProxyGui.ps1` from Korean to English**, at the user's explicit
   request — this is published on a public GitHub repo, so English is the
   right default, and it also makes the encoding class of bug structurally
   impossible for this file going forward (pure ASCII has no
   codepage-misinterpretation risk).

`install-windows.ps1` already has a BOM (fixed earlier, see git history).
`.env` is the **opposite** case: it must NOT have a BOM (a BOM there breaks
plain-`utf-8` readers that don't expect one), so it's written with explicit
`UTF8Encoding($false)`. Two different files, two different rules — don't
conflate them if editing either again.

### Verify
```powershell
git pull
powershell -ExecutionPolicy Bypass -File gui\VertexProxyGui.ps1
```
Should now show the WPF window with no parse errors. If something is still
wrong, it will be a *different* bug than the one described above — check
`gui\crash.log` (should now actually get written on any runtime error) and
`gui\launch-stdout.log` / `gui\launch-stderr.log` (written by
`vertex-openai-proxy-GUI-run.bat` and by `install-windows.ps1`'s own
"open it now?" prompt).

### Architecture notes (for future changes to this file)
- Pure **PowerShell + WPF** (`Add-Type -AssemblyName PresentationFramework`,
  XAML loaded via `[Windows.Markup.XamlReader]::Load`), not Python — two
  earlier attempts (CustomTkinter, then pywebview) hit environment-specific
  dependency problems that were painful to diagnose without a Windows
  machine to test on. WPF ships with Windows itself.
- Reference implementation for this pattern: `nicekriss/Sage-and-Triton-one-shot`
  on GitHub (a ComfyUI installer GUI using the same approach).
- Node server process management: `Start-Process` with
  `-RedirectStandardOutput`/`-RedirectStandardError` to temp log files,
  polled by a `DispatcherTimer` (file reads never block, unlike reading a
  live process pipe directly).
- Single instance: a named Mutex (`Global\VertexOpenAIProxyGuiMutex`) plus a
  `.gui-instance.lock` PID file, so a second launch can prompt "terminate
  the existing one and reopen?" and target the right process.
- WPF `Brush` properties (`.Fill`, `.Background`) cannot be assigned a raw
  string reliably from PowerShell — use the `ConvertTo-Brush` helper
  (wraps `System.Windows.Media.BrushConverter`).
- The XAML is a PowerShell verbatim here-string (`@'...'@`); both the
  opening `@'` and closing `'@` must be alone on their own line with no
  trailing whitespace.
- Keep all strings in this file (and any new PowerShell script with
  non-ASCII content) either pure ASCII, or double-check the file has a
  UTF-8 BOM — Windows PowerShell 5.1 is the target runtime and has no
  other way to detect the encoding.
