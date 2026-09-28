# Vertex OpenAI Proxy — GUI (`gui/VertexProxyGui.ps1`)

## Status: done, user-confirmed working in daily use

Pure PowerShell + WPF control panel (no Python, no external runtime — WPF
ships with Windows). Launches with no console window, Start/Stop/Restart/
Save & Restart all work against a real node process, `.env` autosave works,
field masking works, the log panel resizes with the window.

**System tray: intentionally not pursued further.** Closing the window (X)
drops it to a taskbar icon rather than the notification-area tray icon near
the clock. The taskbar icon's right-click Jump List (Open / Restart Server /
Quit, via `gui/SendCommand.vbs` + a `.gui-command` file the app polls) works
correctly and the process stays alive — functionally equivalent to a real
tray icon, just a different location. Multiple attempts to get a real
`System.Windows.Forms.NotifyIcon` to actually place an icon (rather than
just flip `.Visible`) failed under WPF's `ShowDialog()` message loop; the
user has decided this isn't worth a full rewrite (e.g. a compiled C#/.NET
app) to chase. **Don't re-attempt this without the user explicitly asking.**

## Architecture notes

- Pure **PowerShell + WPF** (`Add-Type -AssemblyName PresentationFramework`,
  XAML loaded via `[Windows.Markup.XamlReader]::Load`). Chosen after two
  Python-based GUI attempts (CustomTkinter, then pywebview) both hit
  environment-specific dependency problems that were painful to diagnose
  without a Windows machine to test on.
- Launched via `gui/LaunchHidden.vbs` (`WScript.Shell.Run`), not
  `powershell.exe -WindowStyle Hidden` directly — on Windows 11 with
  "Windows Terminal" set as the default terminal app, that OS setting
  intercepts any new console-subsystem process and force-opens it in a
  visible tab regardless of window style. `SetCurrentProcessExplicitAppUserModelID`
  gives the taskbar icon its own identity instead of being grouped under
  generic "Windows PowerShell".
- Node server process management: `Start-Process -RedirectStandardOutput/-RedirectStandardError`
  to temp log files, polled by a `DispatcherTimer` (file reads never block,
  unlike reading a live process pipe directly). `Stop-NodeServer` polls
  `Get-NetTCPConnection` until the port actually clears before restarting —
  don't replace with a fixed sleep, that caused an intermittent EADDRINUSE.
- Single instance: a named Mutex (`Global\VertexOpenAIProxyGuiMutex`) plus a
  `.gui-instance.lock` PID file. Dispose every non-owning mutex handle
  immediately on a failed acquire — not doing so was a real bug (the new
  process ended up holding the old mutex alive, permanently wedging future
  launches).
- WPF `Brush` properties (`.Fill`, `.Background`) cannot be assigned a raw
  string reliably from PowerShell — use the `ConvertTo-Brush` helper
  (wraps `System.Windows.Media.BrushConverter`).
- The XAML is a PowerShell verbatim here-string (`@'...'@`); both the
  opening `@'` and closing `'@` must be alone on their own line with no
  trailing whitespace.
- **Encoding is load-bearing**: `gui/VertexProxyGui.ps1` must keep its UTF-8
  BOM (Windows PowerShell 5.1 misreads a BOM-less file with non-ASCII
  content via the system codepage, corrupting string literals into
  cascading parse errors with no visible cause) — and all its UI/log
  strings are plain ASCII/English on top of that, removing the risk
  entirely rather than just patching one instance of it. `.env` is the
  **opposite** case — it must NOT have a BOM — so don't copy either file's
  encoding handling onto the other.
- Log-file/log-panel: node's stdout/stderr go to per-launch **timestamped**
  filenames (`gui/LaunchHidden.vbs`), not a fixed pair — a locked leftover
  log file (AV/EDR scanning, a lingering handle) made `cmd.exe`'s own
  `1> file` redirection fail to even open it, silently preventing
  `powershell.exe` (the whole GUI) from launching at all.
- Fallback Gemini model list uses `gemini-3.1-pro-preview`, not
  `gemini-3.1-pro` (the latter 404s against Vertex AI).

Full blow-by-blow of every bug found and fixed is in `git log` for this file
and `install-windows.ps1` if you need the detailed history.
