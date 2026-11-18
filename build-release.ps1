<#
.SYNOPSIS
    Builds the Rust tray GUI and assembles a self-contained, portable folder
    (dist\VertexOpenAIProxy) plus a zip. Copy/unzip that folder anywhere and
    double-click VertexOpenAIProxy.exe - no install, no Node.js needed.
#>
param(
    [switch]$NoNode,   # skip bundling node.exe (then Node.js must be installed on the target PC)
    [switch]$NoZip
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSCommandPath
$out  = Join-Path $root "dist\VertexOpenAIProxy"

Push-Location (Join-Path $root "gui-rs")
try { cargo build --release; if ($LASTEXITCODE) { throw "cargo build failed" } } finally { Pop-Location }

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

Copy-Item (Join-Path $root "gui-rs\target\release\vertex-proxy-gui.exe") (Join-Path $out "VertexOpenAIProxy.exe")
foreach ($f in "index.js", "auth.js", "package.json", "package-lock.json", ".env.example", "LICENSE") {
    $p = Join-Path $root $f
    if (Test-Path $p) { Copy-Item $p $out }
}

# Production dependencies only, installed fresh into the release folder.
Push-Location $out
try { npm ci --omit=dev --no-audit --no-fund; if ($LASTEXITCODE) { throw "npm ci failed" } } finally { Pop-Location }

if (-not $NoNode) {
    $node = (Get-Command node -ErrorAction Stop).Source
    New-Item -ItemType Directory -Path (Join-Path $out "node") | Out-Null
    Copy-Item $node (Join-Path $out "node\node.exe")
}

@"
Vertex OpenAI Proxy - portable
==============================
1. Double-click VertexOpenAIProxy.exe  (it lives in the system tray).
2. Enter your Google Cloud Project ID and press Save & Restart.
   (Authentication: run 'gcloud auth application-default login' once, or set
   GOOGLE_APPLICATION_CREDENTIALS in .env.)
3. Closing the window keeps it running in the tray; right-click the tray icon to quit.

Everything (settings .env, logs, server) stays inside this folder.
"@ | Set-Content (Join-Path $out "README.txt") -Encoding UTF8

if (-not $NoZip) {
    $zip = Join-Path $root "dist\VertexOpenAIProxy.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path $out -DestinationPath $zip
    Write-Host "Zip: $zip"
}
Write-Host "Release folder: $out"
