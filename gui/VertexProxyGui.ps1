<#
.SYNOPSIS
    Vertex OpenAI Proxy control panel (pure PowerShell + WPF, no Python).
.DESCRIPTION
    Starts/stops/restarts the Node.js proxy server, edits .env (project id,
    location, model, port), and minimizes to the Windows system tray instead
    of leaving a console window open.

    Deliberately built on WPF (System.Windows / PresentationFramework) rather
    than any Python GUI toolkit: WPF ships with every Windows install (it's
    part of .NET, already used by install-windows.ps1 itself), so there is no
    separate runtime/package to install, no version to mismatch, and nothing
    that can silently fail to initialize the way a Python interpreter, pip
    package, or embedded browser engine can.
.NOTES
    Run hidden (no console window):
        powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\VertexProxyGui.ps1
#>

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Error handling MUST come first, before anything that could fail (including
# Add-Type). If a real problem (e.g. a mistyped path) previously slipped
# through before this was wired up, the script would die instantly with zero
# visible output under -WindowStyle Hidden — indistinguishable from "nothing
# happens". This block only needs Split-Path/Join-Path (always available)
# and System.Windows.Forms (present on every Windows install, unlike WPF's
# PresentationFramework which is loaded further below and could in principle
# fail on a stripped-down Windows) so it can report a failure at ANY point.
# ---------------------------------------------------------------------------
$ScriptDir = Split-Path -Parent $PSCommandPath
$ProjectRoot = Split-Path -Parent $ScriptDir
$EnvPath = Join-Path $ProjectRoot ".env"
$CrashLogPath = Join-Path $ScriptDir "crash.log"
$LockPidPath = Join-Path $ProjectRoot ".gui-instance.lock"
$CommandFilePath = Join-Path $ScriptDir ".gui-command"
$MutexName = "Global\VertexOpenAIProxyGuiMutex"

function Write-CrashLog {
    param($ErrorRecord)
    try {
        $text = "`n" + ("=" * 70) + "`n" + (Get-Date -Format "yyyy-MM-dd HH:mm:ss") + "`n" + ($ErrorRecord | Out-String)
        Add-Content -LiteralPath $CrashLogPath -Value $text -Encoding UTF8
    } catch {}
}

try {
    Add-Type -AssemblyName System.Windows.Forms
} catch {
    # Can't even show a MessageBox at this point; the .bat's own output
    # redirection (2> launch-stderr.log) is the only thing that can surface
    # this. Re-throw so PowerShell's own error text still goes to stderr.
    throw
}

trap {
    Write-CrashLog $_
    try {
        [System.Windows.Forms.MessageBox]::Show(
            "An error occurred.`n$($_.Exception.Message)`n`nDetails: $CrashLogPath",
            "Vertex OpenAI Proxy", [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {}
    exit 1
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Drawing

# Give this window its own taskbar identity. Without this, Windows groups
# it under the generic "Windows PowerShell" taskbar icon (since that's the
# actual hosting process) and its right-click jump list shows PowerShell's
# own generic entries (Run as Administrator, ISE, ...) instead of anything
# related to this app — confusing, and easy to mistake for a missing
# system tray icon.
try {
    Add-Type -TypeDefinition @"
using System.Runtime.InteropServices;
public class VertexProxyAppId {
    [DllImport("shell32.dll", SetLastError = true)]
    public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string AppID);
}
"@
    [void][VertexProxyAppId]::SetCurrentProcessExplicitAppUserModelID("VertexOpenAIProxy.GUI")
} catch {
    # Cosmetic only — never let this block startup.
}

# SetCurrentProcessExplicitAppUserModelID (above) only changes taskbar
# *grouping* identity — it does NOT change what the right-click jump list
# shows. Without this, Windows falls back to generic PowerShell entries
# (Run as Administrator, ISE, ...) because that's still the literal hosting
# executable. WPF's System.Windows.Shell.JumpList wraps the underlying
# ICustomDestinationList COM API to register real, app-specific tasks.
# Each task shells out to SendCommand.vbs (no visible window, unlike
# invoking powershell.exe directly) which just writes a one-word command to
# $CommandFilePath; the running instance's DispatcherTimer picks it up.
try {
    $sendCommandPath = Join-Path $ScriptDir "SendCommand.vbs"
    $script:WpfApp = [System.Windows.Application]::Current
    if (-not $script:WpfApp) { $script:WpfApp = New-Object System.Windows.Application }
    # Without this, WPF's own Application object defaults to ShutdownMode
    # "OnLastWindowClose" and auto-tracks any Window created while
    # Application.Current exists (which $window, created further below,
    # will be) — so the whole process can quit itself out from under our
    # own Closing handler's e.Cancel/Hide() hide-to-tray logic. This
    # Application object only exists to host the Jump List; it must never
    # drive process lifetime on its own.
    $script:WpfApp.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown

    $jumpList = New-Object System.Windows.Shell.JumpList
    foreach ($t in @(
        @{ Title = "Open"; Cmd = "open" },
        @{ Title = "Restart Server"; Cmd = "restart" },
        @{ Title = "Quit"; Cmd = "quit" }
    )) {
        $task = New-Object System.Windows.Shell.JumpTask
        $task.Title = $t.Title
        $task.ApplicationPath = "$env:WINDIR\System32\wscript.exe"
        $task.Arguments = "`"$sendCommandPath`" $($t.Cmd)"
        $task.CustomCategory = "Vertex OpenAI Proxy"
        [void]$jumpList.JumpItems.Add($task)
    }
    [System.Windows.Shell.JumpList]::SetJumpList($script:WpfApp, $jumpList)
    $jumpList.Apply()
} catch {
    # Cosmetic only — never let this block startup.
}

$FallbackModels = @(
    "gemini-3.7-flash",
    "gemini-3.1-pro-preview",
    "gemini-3.8-flash",
    "gemini-1.5-pro-002",
    "gemini-1.5-flash-002"
)

# ---------------------------------------------------------------------------
# Single-instance guard
# ---------------------------------------------------------------------------
$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)

if (-not $createdNew) {
    $mutex.Dispose()
    $existingPid = $null
    if (Test-Path -LiteralPath $LockPidPath) {
        try { $existingPid = [int]((Get-Content -LiteralPath $LockPidPath -Raw).Trim()) } catch {}
    }
    $pidNote = if ($existingPid) { " (PID $existingPid)" } else { "" }
    $answer = [System.Windows.MessageBox]::Show(
        "An instance is already running$pidNote.`n`nTerminate it and open a new one?",
        "Vertex OpenAI Proxy", "YesNo", "Question")
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { exit 0 }

    # Ask the existing instance to quit itself first (it releases the mutex
    # cleanly via Quit-App) instead of immediately force-killing whatever
    # PID happens to be in the lock file. That PID file can go stale — e.g.
    # a prior instance that crashed without cleaning it up, or (on a
    # long-running machine) plain PID reuse by an unrelated process — in
    # which case Stop-Process kills the wrong thing while the real mutex
    # holder survives, and every retry fails the same way.
    try { [System.IO.File]::WriteAllText($CommandFilePath, "quit") } catch {}

    # Each failed attempt below still opens a real handle to the named
    # mutex. If it's never closed, THIS process ends up being the one
    # keeping the kernel object alive — so every subsequent attempt reports
    # "already exists" forever, even after the other instance is long gone.
    # Dispose every non-owning handle immediately so only the real owner
    # (if any) keeps it alive.
    $acquired = $false
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 250
        $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
        if ($createdNew) { $acquired = $true; break }
        $mutex.Dispose()
    }

    if (-not $acquired -and $existingPid) {
        # Graceful quit didn't land in time (e.g. the running instance
        # predates this command-file mechanism, or it's stuck) — fall back
        # to a hard kill by PID as a last resort.
        try { Stop-Process -Id $existingPid -Force -ErrorAction SilentlyContinue } catch {}
        Start-Sleep -Milliseconds 500
        $mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$createdNew)
        $acquired = $createdNew
    }

    if (-not $acquired) {
        [System.Windows.MessageBox]::Show(
            "Failed to terminate the existing instance. Please close it from Task Manager and try again.",
            "Vertex OpenAI Proxy", "OK", "Error") | Out-Null
        exit 1
    }
}
Set-Content -LiteralPath $LockPidPath -Value $PID -Encoding UTF8

# ---------------------------------------------------------------------------
# .env helpers (only touch the keys we manage; leave everything else as-is)
# ---------------------------------------------------------------------------
$EnvKeys = @("GOOGLE_CLOUD_PROJECT_ID", "GOOGLE_CLOUD_LOCATION", "GOOGLE_CLOUD_MODEL_ID", "PORT")

function Read-EnvValues {
    $values = [ordered]@{
        GOOGLE_CLOUD_PROJECT_ID = ""
        GOOGLE_CLOUD_LOCATION   = "global"
        GOOGLE_CLOUD_MODEL_ID   = "gemini-3.7-flash"
        PORT                    = "3000"
    }
    if (Test-Path -LiteralPath $EnvPath) {
        foreach ($line in (Get-Content -LiteralPath $EnvPath -Encoding UTF8)) {
            $trimmed = $line.Trim()
            if (-not $trimmed -or $trimmed.StartsWith("#") -or -not $trimmed.Contains("=")) { continue }
            $idx = $trimmed.IndexOf("=")
            $key = $trimmed.Substring(0, $idx).Trim()
            $val = $trimmed.Substring($idx + 1).Trim()
            if ($values.Contains($key)) { $values[$key] = $val }
        }
    }
    return $values
}

function Write-EnvValues {
    param([hashtable]$Values)
    $outLines = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    if (Test-Path -LiteralPath $EnvPath) {
        foreach ($line in (Get-Content -LiteralPath $EnvPath -Encoding UTF8)) {
            $trimmed = $line.TrimEnd()
            $key = $null
            if ($trimmed.Contains("=")) { $key = $trimmed.Substring(0, $trimmed.IndexOf("=")).Trim() }
            if ($EnvKeys -contains $key) {
                if ($seen.ContainsKey($key)) { continue }  # drop duplicate/stale lines
                $outLines.Add("$key=$($Values[$key])")
                $seen[$key] = $true
            } else {
                $outLines.Add($trimmed)
            }
        }
    }
    foreach ($key in $EnvKeys) {
        if (-not $seen.ContainsKey($key)) { $outLines.Add("$key=$($Values[$key])") }
    }
    # Explicit no-BOM UTF-8, so nothing downstream (Node's dotenv, this script
    # next time) ever has to deal with a BOM-glued first key again.
    [System.IO.File]::WriteAllLines($EnvPath, $outLines, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-LiveModels {
    param([string]$Port)
    try {
        $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/models" -TimeoutSec 2 -ErrorAction Stop
        return @($resp.data | Where-Object { $_.id -like "gemini-*" } | ForEach-Object { $_.id })
    } catch {
        return @()
    }
}

# ---------------------------------------------------------------------------
# UI (XAML)
# ---------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Vertex OpenAI Proxy"
        Width="720" Height="700" MinWidth="560" MinHeight="480"
        WindowStartupLocation="CenterScreen"
        ResizeMode="CanResizeWithGrip"
        Background="#F1E3D3"
        FontFamily="Segoe UI">
  <Window.Resources>
    <Style x:Key="PastelButton" TargetType="Button">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Height" Value="38"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" CornerRadius="14" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Opacity" Value="0.82"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Background" Value="#D8D0C4"/>
                <Setter Property="Foreground" Value="#8A8272"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid x:Name="RootGrid" Margin="22">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <TextBlock Grid.Row="0" Text="Vertex OpenAI Proxy" FontSize="21" FontWeight="Bold" Foreground="#1A1A1A" Margin="0,0,0,10"/>

    <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,18">
      <Ellipse x:Name="StatusDot" Width="10" Height="10" Fill="#B23B3B" VerticalAlignment="Center"/>
      <TextBlock x:Name="StatusText" Text="Stopped" FontWeight="Bold" FontSize="13" Foreground="#1A1A1A" Margin="8,0,0,0" VerticalAlignment="Center"/>
    </StackPanel>

    <Grid Grid.Row="2" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="190"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="42"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="Google Cloud Project ID" FontWeight="Bold" FontSize="12" Grid.Column="0" VerticalAlignment="Center"/>
      <Border Grid.Column="1" Background="White" CornerRadius="14" Height="36" Margin="0,0,8,0">
        <Grid>
          <PasswordBox x:Name="ProjectIdPasswordBox" Background="Transparent" BorderThickness="0"
                       Padding="12,0" VerticalContentAlignment="Center" FontSize="13"/>
          <TextBox x:Name="ProjectIdTextBox" Background="Transparent" BorderThickness="0"
                   Padding="12,0" VerticalContentAlignment="Center" FontSize="13" Visibility="Collapsed"/>
        </Grid>
      </Border>
      <Button x:Name="ToggleMaskButton" Content="&#128065;" Grid.Column="2" Width="36" Height="36"
              Style="{StaticResource PastelButton}" Background="White" Foreground="Black" FontSize="14"/>
    </Grid>

    <Grid Grid.Row="3" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="190"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="Location" FontWeight="Bold" FontSize="12" VerticalAlignment="Center"/>
      <Border Grid.Column="1" Background="White" CornerRadius="14" Height="36">
        <TextBox x:Name="LocationTextBox" Background="Transparent" BorderThickness="0"
                 Padding="12,0" VerticalContentAlignment="Center" FontSize="13"/>
      </Border>
    </Grid>

    <Grid Grid.Row="4" Margin="0,0,0,10">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="190"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="Gemini Model" FontWeight="Bold" FontSize="12" VerticalAlignment="Center"/>
      <Border Grid.Column="1" Background="White" CornerRadius="14" Height="36">
        <ComboBox x:Name="ModelComboBox" IsEditable="True" Background="Transparent" BorderThickness="0"
                  FontSize="13" VerticalContentAlignment="Center" Padding="10,0"/>
      </Border>
    </Grid>

    <Grid Grid.Row="5" Margin="0,0,0,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="190"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>
      <TextBlock Text="Port" FontWeight="Bold" FontSize="12" VerticalAlignment="Center"/>
      <Border Grid.Column="1" Background="White" CornerRadius="14" Height="36">
        <TextBox x:Name="PortTextBox" Background="Transparent" BorderThickness="0"
                 Padding="12,0" VerticalContentAlignment="Center" FontSize="13"/>
      </Border>
    </Grid>

    <UniformGrid Grid.Row="6" Rows="1" Columns="4" Margin="0,0,0,12">
      <Button x:Name="StartButton" Content="Start" Margin="0,0,8,0" Style="{StaticResource PastelButton}" Background="#B7E4C7" Foreground="Black"/>
      <Button x:Name="StopButton" Content="Stop" Margin="0,0,8,0" Style="{StaticResource PastelButton}" Background="#F4A9A8" Foreground="Black"/>
      <Button x:Name="RestartButton" Content="Restart" Margin="0,0,8,0" Style="{StaticResource PastelButton}" Background="#A9C7F4" Foreground="Black"/>
      <Button x:Name="SaveButton" Content="Save &amp; Restart" Style="{StaticResource PastelButton}" Background="#F7D794" Foreground="Black"/>
    </UniformGrid>

    <TextBlock Grid.Row="7" Text="Closing this window minimizes it to the system tray. Use the tray icon menu to quit completely."
               FontSize="10" Foreground="#5A4E42" Margin="0,0,0,12" TextWrapping="Wrap"/>

    <TextBlock Grid.Row="8" x:Name="LogToggleText" Text="&#9660;  Log" FontWeight="Bold" FontSize="11"
               Foreground="#1A1A1A" Cursor="Hand" Margin="0,0,0,8"/>

    <Border Grid.Row="9" x:Name="LogPanel" Background="#1A1A1A" CornerRadius="16" MinHeight="120">
      <TextBox x:Name="LogBox" Background="Transparent" Foreground="White" BorderThickness="0"
               FontFamily="Consolas" FontSize="11" Margin="14"
               TextWrapping="Wrap" AcceptsReturn="True" IsReadOnly="True"
               VerticalScrollBarVisibility="Auto"/>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$RootGrid             = $window.FindName("RootGrid")
$StatusDot            = $window.FindName("StatusDot")
$StatusText           = $window.FindName("StatusText")
$ProjectIdPasswordBox = $window.FindName("ProjectIdPasswordBox")
$ProjectIdTextBox     = $window.FindName("ProjectIdTextBox")
$ToggleMaskButton     = $window.FindName("ToggleMaskButton")
$LocationTextBox      = $window.FindName("LocationTextBox")
$ModelComboBox        = $window.FindName("ModelComboBox")
$PortTextBox          = $window.FindName("PortTextBox")
$StartButton          = $window.FindName("StartButton")
$StopButton           = $window.FindName("StopButton")
$RestartButton        = $window.FindName("RestartButton")
$SaveButton           = $window.FindName("SaveButton")
$LogToggleText        = $window.FindName("LogToggleText")
$LogPanel             = $window.FindName("LogPanel")
$LogBox               = $window.FindName("LogBox")

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------
function Append-Log {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }
    $LogBox.AppendText($Text)
    $LogBox.ScrollToEnd()
}

function Append-LogLine {
    param([string]$Text)
    Append-Log ("[GUI] $Text`r`n")
}

$script:BrushConverter = New-Object System.Windows.Media.BrushConverter
function ConvertTo-Brush {
    param([string]$Hex)
    return $script:BrushConverter.ConvertFromString($Hex)
}

function Set-Status {
    param([bool]$Running)
    if ($Running) {
        $StatusDot.Fill = ConvertTo-Brush "#3B8F5C"
        $StatusText.Text = "Running"
    } else {
        $StatusDot.Fill = ConvertTo-Brush "#B23B3B"
        $StatusText.Text = "Stopped"
    }
}

$script:ProjectIdMasked = $true
function Get-ProjectIdValue {
    if ($script:ProjectIdMasked) { return $ProjectIdPasswordBox.Password }
    return $ProjectIdTextBox.Text
}
function Set-ProjectIdValue {
    param([string]$Value)
    $ProjectIdPasswordBox.Password = $Value
    $ProjectIdTextBox.Text = $Value
}
$ToggleMaskButton.Add_Click({
    if ($script:ProjectIdMasked) {
        $ProjectIdTextBox.Text = $ProjectIdPasswordBox.Password
        $ProjectIdPasswordBox.Visibility = "Collapsed"
        $ProjectIdTextBox.Visibility = "Visible"
        $script:ProjectIdMasked = $false
    } else {
        $ProjectIdPasswordBox.Password = $ProjectIdTextBox.Text
        $ProjectIdTextBox.Visibility = "Collapsed"
        $ProjectIdPasswordBox.Visibility = "Visible"
        $script:ProjectIdMasked = $true
    }
})

$script:LogVisible = $true
$LogRowDefinition = $RootGrid.RowDefinitions[9]
$LogToggleText.Add_MouseLeftButtonUp({
    $script:LogVisible = -not $script:LogVisible
    if ($script:LogVisible) {
        $LogPanel.Visibility = "Visible"
        $LogToggleText.Text = "$([char]0x25BC)  Log"
        $LogRowDefinition.Height = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
    } else {
        $LogPanel.Visibility = "Collapsed"
        $LogToggleText.Text = "$([char]0x25B6)  Log"
        # A "*" row keeps claiming its share of space even once its only
        # child is Collapsed (star sizing isn't content-driven the way
        # Auto is), which would leave a big dead gap below the buttons.
        # Collapse the row itself while hidden.
        $LogRowDefinition.Height = New-Object System.Windows.GridLength(0)
    }
})

function Get-FormValues {
    return @{
        GOOGLE_CLOUD_PROJECT_ID = (Get-ProjectIdValue).Trim()
        GOOGLE_CLOUD_LOCATION   = $(if ($LocationTextBox.Text.Trim()) { $LocationTextBox.Text.Trim() } else { "global" })
        GOOGLE_CLOUD_MODEL_ID   = $(if ($ModelComboBox.Text.Trim()) { $ModelComboBox.Text.Trim() } else { "gemini-3.7-flash" })
        PORT                    = $(if ($PortTextBox.Text.Trim()) { $PortTextBox.Text.Trim() } else { "3000" })
    }
}

function Load-EnvIntoForm {
    $values = Read-EnvValues
    Set-ProjectIdValue $values.GOOGLE_CLOUD_PROJECT_ID
    $LocationTextBox.Text = $values.GOOGLE_CLOUD_LOCATION
    $PortTextBox.Text = $values.PORT

    $liveModels = Get-LiveModels -Port $values.PORT
    $allModels = @($liveModels + $FallbackModels | Select-Object -Unique)
    $ModelComboBox.Items.Clear()
    foreach ($m in $allModels) { [void]$ModelComboBox.Items.Add($m) }
    $ModelComboBox.Text = $values.GOOGLE_CLOUD_MODEL_ID
}

function Set-ButtonsBusy {
    param([bool]$Busy)
    $StartButton.IsEnabled = -not $Busy
    $StopButton.IsEnabled = -not $Busy
    $RestartButton.IsEnabled = -not $Busy
    $SaveButton.IsEnabled = -not $Busy
}

# ---------------------------------------------------------------------------
# Node process management
# ---------------------------------------------------------------------------
$script:NodeProcess = $null
$script:StdoutPath = Join-Path $env:TEMP "vertex-openai-proxy-out.log"
$script:StderrPath = Join-Path $env:TEMP "vertex-openai-proxy-err.log"
$script:StdoutOffset = 0
$script:StderrOffset = 0
$script:WasRunning = $false

function Sync-EnvIfChanged {
    $current = Read-EnvValues
    $formValues = Get-FormValues
    if ([string]::IsNullOrWhiteSpace($formValues.GOOGLE_CLOUD_PROJECT_ID)) {
        Append-LogLine "ERROR: Please enter a Project ID."
        [System.Windows.MessageBox]::Show("Please enter a Project ID.", "Required", "OK", "Warning") | Out-Null
        return $false
    }
    $changed = $false
    foreach ($k in $EnvKeys) { if ($current[$k] -ne $formValues[$k]) { $changed = $true } }
    if ($changed) {
        Write-EnvValues $formValues
        Append-LogLine "Detected changed settings; saved to .env."
    }
    return $true
}

function Find-NodeExe {
    # Get-Command relies on this process's PATH, which can be stale if Node.js
    # was installed (via winget/nvm) after the launching process (e.g. the
    # user's Explorer.exe session) last refreshed its environment block —
    # a common Windows gotcha where a fresh install is invisible to
    # already-running processes until logoff/logon. Fall back to the
    # well-known install locations before giving up.
    $nodeCmd = Get-Command node -ErrorAction SilentlyContinue
    if ($nodeCmd) { return $nodeCmd.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles "nodejs\node.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\nodejs\node.exe")
    )
    $nvmDir = Join-Path $env:APPDATA "nvm"
    if (Test-Path -LiteralPath $nvmDir) {
        $symlink = Join-Path $nvmDir "node.exe"
        if (Test-Path -LiteralPath $symlink) { $candidates += $symlink }
        $candidates += (Get-ChildItem -LiteralPath $nvmDir -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName "node.exe" })
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Start-NodeServer {
    if ($script:NodeProcess -and -not $script:NodeProcess.HasExited) {
        Append-LogLine "Already running."
        return
    }
    if (-not (Sync-EnvIfChanged)) { return }

    $nodeExe = Find-NodeExe
    if (-not $nodeExe) {
        Append-LogLine "ERROR: Could not find the node executable. Please make sure Node.js is installed."
        [System.Windows.MessageBox]::Show("Could not find the node executable. Please make sure Node.js is installed.", "Error", "OK", "Error") | Out-Null
        return
    }

    # Start-Process's own -RedirectStandardOutput/-RedirectStandardError
    # (below) already truncates/recreates these files when it opens them,
    # so no pre-deletion is needed. It used to happen here too, via
    # Remove-Item + New-Item -Force — but right after Stop-NodeServer kills
    # the previous node process (e.g. on Restart), Windows can take a brief
    # moment to fully release its handle on this same file, and New-Item
    # -Force has no -ErrorAction guard, so that race would throw a
    # terminating "file in use" error straight out of $ErrorActionPreference
    # = Stop and take the whole GUI down with it. Just reset the offsets;
    # let Start-Process own file creation entirely.
    $script:StdoutOffset = 0
    $script:StderrOffset = 0

    try {
        $proc = Start-Process -FilePath $nodeExe -ArgumentList "index.js" `
            -WorkingDirectory $ProjectRoot -WindowStyle Hidden -PassThru `
            -RedirectStandardOutput $script:StdoutPath -RedirectStandardError $script:StderrPath
    } catch {
        Append-LogLine "ERROR: Failed to start server: $($_.Exception.Message)"
        [System.Windows.MessageBox]::Show("Failed to start server: $($_.Exception.Message)", "Error", "OK", "Error") | Out-Null
        return
    }

    $script:NodeProcess = $proc
    $script:WasRunning = $true
    Set-Status $true
    Append-LogLine "Server started."
}

function Stop-NodeServer {
    if (-not $script:NodeProcess -or $script:NodeProcess.HasExited) {
        Append-LogLine "No server is running."
        Set-Status $false
        return
    }
    try {
        $script:NodeProcess.Kill()
        $script:NodeProcess.WaitForExit(5000) | Out-Null
    } catch {}
    # Killing the process doesn't guarantee Windows has released the TCP
    # port it was listening on yet — a Restart that immediately tries to
    # bind the same port can lose that race with EADDRINUSE. Poll instead
    # of a fixed sleep so this doesn't wait any longer than it has to.
    $portValue = $PortTextBox.Text.Trim()
    if ($portValue) {
        for ($i = 0; $i -lt 20; $i++) {
            $stillBound = Get-NetTCPConnection -LocalPort $portValue -State Listen -ErrorAction SilentlyContinue
            if (-not $stillBound) { break }
            Start-Sleep -Milliseconds 150
        }
    }
    $script:WasRunning = $false
    Set-Status $false
    Append-LogLine "Server stopped."
}

function Restart-NodeServer {
    Stop-NodeServer
    Start-Sleep -Milliseconds 300
    Start-NodeServer
}

function Read-NewLogContent {
    param([string]$Path, [string]$OffsetVarName)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $offset = Get-Variable -Name $OffsetVarName -Scope Script -ValueOnly
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        if ($fs.Length -le $offset) { return }
        $fs.Seek($offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buffer = New-Object byte[] ($fs.Length - $offset)
        [void]$fs.Read($buffer, 0, $buffer.Length)
        Set-Variable -Name $OffsetVarName -Scope Script -Value $fs.Length
        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
        if ($text) { Append-Log $text }
    } finally {
        if ($fs) { $fs.Close() }
    }
}

# Polls for new Node output and detects the process exiting on its own —
# a DispatcherTimer tick runs on the same UI thread as ShowDialog()'s message
# loop, so this is safe without any cross-thread marshaling.
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(400)
$timer.Add_Tick({
    Read-NewLogContent -Path $script:StdoutPath -OffsetVarName "StdoutOffset"
    Read-NewLogContent -Path $script:StderrPath -OffsetVarName "StderrOffset"
    if ($script:WasRunning -and $script:NodeProcess -and $script:NodeProcess.HasExited) {
        $script:WasRunning = $false
        Set-Status $false
        Append-LogLine "Server process exited."
    }
    # Taskbar Jump List tasks can't call back into this process directly, so
    # they write a one-word command to $CommandFilePath (via SendCommand.vbs)
    # instead; pick it up here on the same poll that already checks the
    # server's log files.
    if (Test-Path -LiteralPath $CommandFilePath) {
        $cmd = $null
        try { $cmd = (Get-Content -LiteralPath $CommandFilePath -Raw -ErrorAction Stop).Trim() } catch {}
        Remove-Item -LiteralPath $CommandFilePath -ErrorAction SilentlyContinue
        switch ($cmd) {
            "open"    { Show-MainWindow }
            "restart" { Restart-NodeServer }
            "quit"    { Quit-App }
        }
    }
})
$timer.Start()

$StartButton.Add_Click({ Start-NodeServer })
$StopButton.Add_Click({ Stop-NodeServer })
$RestartButton.Add_Click({ Restart-NodeServer })
$SaveButton.Add_Click({
    $formValues = Get-FormValues
    if ([string]::IsNullOrWhiteSpace($formValues.GOOGLE_CLOUD_PROJECT_ID)) {
        Append-LogLine "ERROR: Please enter a Project ID."
        [System.Windows.MessageBox]::Show("Please enter a Project ID.", "Required", "OK", "Warning") | Out-Null
        return
    }
    Write-EnvValues $formValues
    Append-LogLine "Saved .env. Restarting server..."
    Restart-NodeServer
})

# ---------------------------------------------------------------------------
# System tray
# ---------------------------------------------------------------------------
$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$notifyIcon.Text = "Vertex OpenAI Proxy"
$notifyIcon.Visible = $false

$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuOpen = $contextMenu.Items.Add("Open")
$menuRestartServer = $contextMenu.Items.Add("Restart Server")
$menuRestartApp = $contextMenu.Items.Add("Restart GUI (relaunch process)")
$menuQuit = $contextMenu.Items.Add("Quit")
$notifyIcon.ContextMenuStrip = $contextMenu

function Show-MainWindow {
    $window.Show()
    $window.WindowState = "Normal"
    $window.Activate()
    $notifyIcon.Visible = $false
}

$menuOpen.Add_Click({ Show-MainWindow })
$notifyIcon.Add_DoubleClick({ Show-MainWindow })
$menuRestartServer.Add_Click({ Restart-NodeServer })

$script:ForceClose = $false

function Quit-App {
    Stop-NodeServer
    $timer.Stop()
    $script:ForceClose = $true
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    try { $mutex.ReleaseMutex() } catch {}
    Remove-Item -LiteralPath $LockPidPath -ErrorAction SilentlyContinue
    $window.Close()
}

function Restart-FullApp {
    Stop-NodeServer
    $timer.Stop()
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
    try { $mutex.ReleaseMutex() } catch {}
    Remove-Item -LiteralPath $LockPidPath -ErrorAction SilentlyContinue
    # Relaunch via the VBS wrapper (WScript.Shell.Run), not
    # "powershell.exe -WindowStyle Hidden" directly — on Windows 11 with
    # Windows Terminal set as the default terminal app, that setting
    # force-opens any new console-subsystem process in a visible tab
    # regardless of the requested window style. See LaunchHidden.vbs.
    $launchVbsPath = Join-Path $ScriptDir "LaunchHidden.vbs"
    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$launchVbsPath`"" -WorkingDirectory $ProjectRoot
    $script:ForceClose = $true
    $window.Close()
}

$menuRestartApp.Add_Click({ Restart-FullApp })
$menuQuit.Add_Click({ Quit-App })

$window.Add_Closing({
    param($sender, $e)
    if (-not $script:ForceClose) {
        $e.Cancel = $true
        $window.Hide()
        $notifyIcon.Visible = $true
    }
})

# ---------------------------------------------------------------------------
# Startup
# ---------------------------------------------------------------------------
Load-EnvIntoForm
[void]$window.ShowDialog()

# ShowDialog() only returns once Quit-App/Restart-FullApp actually closed the
# window; make sure nothing (timer, tray icon) keeps the process alive after that.
[Environment]::Exit(0)
