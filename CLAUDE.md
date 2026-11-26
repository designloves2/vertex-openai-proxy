# Vertex OpenAI Proxy — GUI (`gui/VertexProxyGui.ps1`)

## Status: done, user-confirmed working in daily use

Pure PowerShell + WPF control panel (no Python, no external runtime — WPF
ships with Windows). Launches with no console window, Start/Stop/Restart/
Save & Restart all work against a real node process, `.env` autosave works,
field masking works, the log panel resizes with the window.

**System tray: solved by the Rust rewrite (`gui-rs/`), not the PowerShell GUI.**
The PowerShell/WPF GUI can't place a real notification-area icon (a
`System.Windows.Forms.NotifyIcon` never shows under WPF's `ShowDialog()`
message loop); closing its window drops to a taskbar icon with a Jump List
(Open / Restart Server / Quit via `gui/SendCommand.vbs` + a polled
`.gui-command` file) instead. **Don't try to fix the tray in the PowerShell
GUI** — the Rust app is the tray-capable one.

## WinUI 3 app (`gui-win/`) — current Windows GUI (v2.0.0+)

C# / WinUI 3 (Windows App SDK 1.6), unpackaged and **self-contained** (no .NET
or Windows App SDK runtime needed on the target PC). Replaced the Rust GUI
because its classic Win32 controls looked dated, clipped text and did not
resize. `build-release.ps1` now ships this app; `gui-rs/` is kept only as
reference/history.

- Layout (user-decided): main screen = server status + Start/Stop/Restart,
  **Connection** card (Project ID / Location / default model / Port, edited in
  place, Save & Restart enabled only when changed) and the server log filling
  the rest. A **gear button at the top-left of the title bar** opens Settings
  (App: start with Windows, auto-start server; Updates); Settings has only a
  ← back button. No NavigationView / side menu.
- Project ID is a PasswordBox, hidden by default, with an eye ToggleButton
  (Visible/Hidden) — not `Peek`, the user wants to check typos.
- Responsive in code (`ApplyLayout`), not AdaptiveTrigger (unreliable directly
  in a `Window`): buttons drop below the status < 760 DIP, Connection fields go
  2x2 < 1100 DIP.
- **Title-bar buttons need a passthrough region**
  (`InputNonClientPointerSource.SetRegionRects`), re-applied on the button's
  SizeChanged and on Activated — set only once at startup the button had no
  size yet and never received clicks.
- Editable `ComboBox.Text` set before load is ignored → `SetComboValue` adds
  and selects the item instead.
- Same files/conventions as the Rust GUI so installs carry over: project root =
  nearest ancestor with `index.js`; `.gui-command` (open/restart/quit/settings),
  `.gui-rs-settings` (`auto_start_server`, `auto_check_updates`), Run value
  `VertexOpenAIProxyGui`. A release install repoints that Run value to itself
  on launch (dev builds never do).
- Auto-update: same GitHub `windows-v<version>` releases and the same
  robocopy helper as the Rust updater (`Core/Updater.cs`); version =
  `<Version>` in `VertexOpenAIProxy.csproj`.
- Build: .NET 8 SDK. On this PC it is a **per-user install** in
  `%LOCALAPPDATA%\Microsoft\dotnet` (winget's machine-wide installer stalled on
  a hidden UAC prompt); the system `dotnet` there has only the runtime, so
  `build-release.ps1` checks `dotnet --list-sdks` before falling back to it.
- **First run / Google sign-in** (`Core/GoogleAuth.cs`, Settings > Google
  account): no ADC file (and no GOOGLE_APPLICATION_CREDENTIALS key in .env) ->
  the app opens Settings and runs setup by itself: downloads Google's Cloud CLI
  installer and runs it **silently per-user** (`/S /singleuser`, no wizard, no
  UAC), then `gcloud auth application-default login` opens the browser (the
  user only types ID/password), sets the quota project and restarts the server.
  The installer ignores a %LOCALAPPDATA% override and always installs into the
  real per-user folder (a test with fake APPDATA/LOCALAPPDATA reinstalled this
  PC's gcloud; credentials survived), so FindGcloud checks the shell folder too.
- **Project picker**: list button next to Project ID lists the account's
  projects (Cloud Resource Manager v1, token from
  `gcloud auth application-default print-access-token`). After first sign-in
  with an empty project ID it auto-fills a single project or opens the list,
  and saves. MenuFlyout popups are separate windows: PrintWindow does not
  capture them, use CopyFromScreen for those.
- Screenshots for checking the UI: `PrintWindow` with flag 2 works on the WinUI
  window even when it is partly off-screen; `CopyFromScreen` does not.

## Rust GUI (`gui-rs/`) — superseded by gui-win (kept for reference)

Native Win32 via `native-windows-gui` (Rust only, no C++). Closing the window
hides it to the tray; tray left-click = open, right-click = Open / Restart
Server / Quit. Options: "Start with Windows" (`HKCU\...\Run`, launched with
`--minimized`) and "Auto-start server on launch" (`.gui-rs-settings`).

- **Needs the embedded Common Controls v6 manifest** (`app.manifest` +
  `app.rc` + `build.rs` via `embed-resource`). Without it the exe fails at
  startup with "GetWindowSubclass not found" and the window never appears.
- Project root = nearest ancestor folder of the exe containing `index.js`.
  `.gui-command` / `.gui-rs-settings` live in that root (not `gui/`). The
  exe prefers a bundled `node\node.exe` in the root over PATH.
- `quit()` calls `std::process::exit(0)`; `stop_thread_dispatch` alone left
  the process alive.
- Before spawning node it checks the port; a leftover node (e.g. orphaned by
  killing the old PowerShell GUI) holding it otherwise caused EADDRINUSE.
- Release: `build-release.ps1` builds and assembles `dist/VertexOpenAIProxy/`
  (exe + node runtime + server + prod `node_modules`) and a zip; published as
  GitHub release `windows-v1.0`. `.env` is never included.
- **Auto-update** (`gui-rs/src/update.rs`): on launch and every 24h the app
  queries `api.github.com/repos/designloves2/vertex-openai-proxy/releases`
  for the newest non-prerelease `windows-v<X.Y[.Z]>` tag with a `.zip` asset
  that is newer than the exe's **Cargo.toml version** (`CARGO_PKG_VERSION`).
  So each release must bump `gui-rs/Cargo.toml` and be tagged
  `windows-v<that version>` (`build-release.ps1` prints the `gh release create`
  line). On user confirm it downloads/extracts with Windows' own `curl.exe` /
  `tar.exe` (no HTTP/zip crates), then a hidden `apply-update.cmd` in %TEMP%
  waits for the exe's PID to exit, `robocopy /E /XF .env .gui-rs-settings`
  over the install folder, and relaunches. Self-update is refused when the
  exe isn't directly next to `index.js` (dev builds under `gui-rs\target`).
  Helper output: `update.log` in the install folder. The helper avoids
  `timeout` (fails without a console) and uses `ping` for delays.
- No model picker by design beyond the `.env` fallback: the connecting
  client chooses the model per request.

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

# Node proxy (`index.js`) — 500 error with large `tools` arrays

## Status: fixed, user-confirmed via a 96-tool request test

## Symptom
`POST /v1/chat/completions` returned HTTP 500 with
`{"error":{"message":"Unexpected non-whitespace character after JSON at
position 30 (line 1 column 31)","type":"api_error"}}` specifically when the
request's `tools` array was large (~96 entries from a client sending many
function definitions at once). 0–3 tools always worked.

## Root cause
Line ~672, inside `openAiMessagesToGeminiContents()`, when replaying an
assistant `tool_calls` turn back to Gemini:
```js
const funcArgs = typeof tc.function.arguments === 'string'
    ? JSON.parse(tc.function.arguments || '{}')
    : tc.function.arguments;
```
This `JSON.parse` had no try/catch, unlike the near-identical tool-response
parsing a few lines below it (~line 706) which already falls back safely on
a parse failure. With a large number of tools in play, a malformed/partial
`arguments` string from the client is far more likely to occur, and when it
did, the raw `SyntaxError` propagated uncaught all the way to the route's
top-level `catch`, which puts `error.message` directly into the client-facing
JSON body — hence the client seeing a raw V8 JSON-parser error string
instead of a normal API error.

## Fix
Wrapped that `JSON.parse` in the same try/catch pattern as the tool-response
parser, falling back to `{}` on failure instead of throwing.

## Also fixed (found during investigation, real bug but not the actual
## trigger here — the exercised streaming path was already protected)
`callGeminiAPI()`, `_doCallGeminiAPI()`, and the legacy `/chat` endpoint
accumulated the HTTPS response body with `data += chunk` — concatenating raw
`Buffer` chunks onto a string one piece at a time. This can corrupt a
multi-byte UTF-8 character if it's split across a chunk boundary (Node
converts each `Buffer` piece independently with the default encoding). Fixed
by collecting chunks into an array and doing a single `Buffer.concat(...).
toString('utf8')` after `'end'`. Note: the actual `/v1/chat/completions`
streaming path was already safe because it calls `proxyRes.setEncoding
('utf8')`, which makes Node decode multi-byte sequences correctly across
chunks internally — only the non-streaming call sites lacked that.

Both fixes are already merged to `main` (commits `825db10`, `42228a2`).

## Note for the macOS app (built separately in Xcode/Swift)

The macOS app is a **fully separate native Swift/Xcode build** — it does not
run this repo's `index.js` at all, and does not reuse any code from here. It
has its own independent reimplementation of the OpenAI-to-Vertex proxy logic
in Swift.

**This means the `index.js` fixes above do NOT carry over automatically.**
They were bug fixes in this repo's specific code, not in `index.js` alone as
a file to copy — the macOS Swift codebase needs the *same two bugs* checked
for and fixed independently in its own logic, if equivalent code exists there:

1. **Unguarded JSON.parse on assistant `tool_calls[].function.arguments`
   when replaying a prior assistant turn back to the model.** If the Swift
   code has an equivalent step (decoding a stored/replayed tool-call's
   arguments string before sending it to Gemini) and that decode isn't
   wrapped in error handling, a malformed/partial arguments string (more
   likely to occur with many tools in flight) will throw and can surface as
   a raw parser-error message in the API response, exactly like the bug
   fixed here. Fix: catch the decode failure and fall back to an empty
   object instead of propagating the raw error.
2. **Buffering an HTTP(S) response body by appending raw bytes/chunks
   directly to a string one piece at a time**, instead of accumulating the
   raw bytes fully and decoding once at the end. If done per-chunk, a
   multi-byte UTF-8 character split across a chunk boundary can get
   corrupted. (Not necessarily a Swift-idiomatic risk the same way — depends
   on which HTTP/URLSession APIs and string-decoding calls are used — but
   worth a quick check of how the Swift code reads Vertex AI's response body.)

**Action needed:** someone (or a local/Mac Claude session) needs to read
through the Swift proxy code's tool-call-argument handling and HTTP
response-reading code and check whether either of these two patterns exists
there, then apply an equivalent fix in Swift. This can't be done from this
cloud session — no Xcode/Swift code exists in this repository to inspect.
