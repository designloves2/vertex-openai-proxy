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
