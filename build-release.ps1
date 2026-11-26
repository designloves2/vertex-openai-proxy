<#
.SYNOPSIS
    Builds the WinUI 3 tray app (gui-win) and assembles a self-contained, portable folder
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

# The app's <Version> is what the in-app updater compares against the GitHub
# release tag windows-v<version>; bump gui-win/VertexOpenAIProxy.csproj for each release.
$csproj = Join-Path $root "gui-win\VertexOpenAIProxy.csproj"
$version = ([xml](Get-Content $csproj -Raw)).Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1
Write-Host "Building version $version"

# .NET 8 SDK: a system install with an SDK, else the per-user one from dotnet-install.ps1.
# A system dotnet with only the runtime (no SDK) can sit first on PATH, so check for an SDK.
$hasSdk = (Get-Command dotnet -ErrorAction SilentlyContinue) -and (dotnet --list-sdks 2>$null)
if (-not $hasSdk -and (Test-Path "$env:LOCALAPPDATA\Microsoft\dotnet\dotnet.exe")) {
    $env:DOTNET_ROOT = "$env:LOCALAPPDATA\Microsoft\dotnet"
    $env:Path = "$env:DOTNET_ROOT;$env:Path"
}
$appOut = Join-Path $root "dist\_app"
if (Test-Path $appOut) { Remove-Item $appOut -Recurse -Force }
dotnet publish $csproj -c Release -o $appOut
if ($LASTEXITCODE) { throw "dotnet publish failed" }

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
New-Item -ItemType Directory -Path $out | Out-Null

# Self-contained WinUI app (exe + .NET + Windows App SDK runtime) at the folder root,
# next to index.js - the layout the in-app updater expects.
Copy-Item (Join-Path $appOut "*") $out -Recurse
Remove-Item $appOut -Recurse -Force
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
    Write-Host "Publish (the app auto-updates from the newest windows-v* release with a .zip asset):"
    Write-Host "  gh release create windows-v$version `"$zip`" --title `"Vertex OpenAI Proxy for Windows (portable) v$version`""
}
Write-Host "Release folder: $out"
