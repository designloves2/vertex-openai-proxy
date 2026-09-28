# Vertex OpenAI Proxy — GUI debugging handoff

## IMPORTANT: your role here is diagnosis, not editing

The user is running a **separate cloud session** that owns `gui/VertexProxyGui.ps1`
and has been iterating on it blind (no Windows/PowerShell available there to
actually execute it). You are running locally and CAN execute it — that's the
capability that session lacks. So:

- **Do not edit `gui/VertexProxyGui.ps1` or `install-windows.ps1` yourself.**
- Run the diagnostic steps below, capture the exact output (full error text,
  stack traces, log file contents), and report it back to the user so they
  can relay it to the other session, which will make the actual fix and push
  it. This avoids two sessions editing the same files out of sync.
- If the user explicitly tells you to fix something directly instead, follow
  that instruction — this file is guidance for the default case, not a hard
  restriction they can't override.

## Current task: fix the Windows GUI control panel (`gui/VertexProxyGui.ps1`)

**Status: broken, unverified.** It was written entirely from a cloud sandbox
with no Windows/PowerShell available to actually run it — every fix so far
has been a best-effort guess based on manual code review. You're running
locally and can actually execute it, so **run the script and report the real
errors** instead of guessing further.

### Symptom as of the last report from the user
Double-clicking `vertex-openai-proxy-GUI-run.bat` shows a console window that
opens and closes almost immediately, with no GUI window ever appearing, and
`gui\crash.log` is not created. This means the PowerShell process is dying
almost instantly — likely before, or during, script initialization — and
doing so silently.

### What to do first
1. `git pull` to make sure you have the latest code (the last few commits
   added output-redirection specifically to catch this class of failure).
2. Run directly with the console visible, no redirection, to see the raw
   error immediately:
   ```powershell
   cd <repo root>
   powershell -ExecutionPolicy Bypass -File gui\VertexProxyGui.ps1
   ```
   If this shows a red error, that's the real bug — go fix it in
   `gui\VertexProxyGui.ps1` at the line/location PowerShell reports.
3. If that runs fine but `vertex-openai-proxy-GUI-run.bat` still doesn't
   show a window, check the two log files it now writes:
   `gui\launch-stdout.log` and `gui\launch-stderr.log`.
4. Also check `gui\crash.log` — the script's own trap handler writes there
   on any runtime (not parse-time) error.

### Architecture (why it's built this way)
- Pure **PowerShell + WPF** (`Add-Type -AssemblyName PresentationFramework`,
  XAML loaded via `[Windows.Markup.XamlReader]::Load`). Deliberately **not**
  Python — two earlier attempts (CustomTkinter, then pywebview) both hit
  environment-specific dependency problems (broken pip/python resolution,
  then what looked like a .NET/WebView2 init hang) that were painful to
  diagnose blind. WPF ships with Windows itself, so there's no separate
  runtime/package to install or version-mismatch.
- The working reference the user pointed to for this approach is
  `nicekriss/Sage-and-Triton-one-shot` on GitHub (a ComfyUI installer GUI
  using the exact same PowerShell+WPF pattern) — worth diffing against if
  something WPF-specific misbehaves, since it's a proven-working example on
  this user's own machine.
- Node server process management: `Start-Process` with
  `-RedirectStandardOutput`/`-RedirectStandardError` to temp log files,
  polled by a `DispatcherTimer` (file reads never block, unlike reading a
  live process pipe directly, which can freeze the UI thread waiting for
  the next line).
- Single instance: a named Mutex (`Global\VertexOpenAIProxyGuiMutex`) plus a
  small `.gui-instance.lock` PID file (so a second launch can prompt
  "terminate the existing one and reopen?" and actually target the right
  process).
- `.env` is read/written with explicit `UTF8Encoding($false)` (no BOM) —
  earlier Python versions had a real bug where a BOM-written `.env` (from
  `Set-Content -Encoding UTF8`, which on Windows PowerShell 5.1 adds a BOM)
  silently broke parsing of the first key. Keep writes BOM-free.

### Known risk areas to check if something's off
- WPF `Brush` properties (`.Fill`, `.Background`) **cannot** be assigned a
  raw string in PowerShell reliably — use the `ConvertTo-Brush` helper
  (wraps `System.Windows.Media.BrushConverter`) already in the script,
  don't assign strings directly.
- The XAML is a PowerShell verbatim here-string (`@'...'@`); both the
  opening `@'` and closing `'@` must be alone on their own line with no
  trailing whitespace, or the parser breaks.
- `-WindowStyle Hidden` only hides the PowerShell console host — the WPF
  window is a separate top-level window and should still appear regardless.
  If the WPF window itself never shows even though the process stays alive,
  suspect `ShowDialog()`/assembly loading rather than the window style flag.

### Once it's actually working
Update this file's status section (or just delete it) and let the user know
what was actually wrong — they've been debugging this blind with you for a
while and want the real root cause, not just "fixed it".
