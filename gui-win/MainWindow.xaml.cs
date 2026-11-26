using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using VertexProxy.Core;

namespace VertexProxy;

public sealed partial class MainWindow : Window
{
    readonly AppPaths _paths;
    readonly ServerManager _server;
    readonly AppOptions _options;
    ProxySettings _saved;
    bool _loading;
    bool _quitting;
    bool _modelsLoaded;
    DateTime _lastModelTry = DateTime.MinValue;
    DateTime _lastUpdateCheck = DateTime.MinValue;
    ReleaseInfo? _pendingRelease;
    readonly Queue<string> _pendingLog = new();
    readonly object _logLock = new();
    readonly StringBuilder _log = new();
    readonly DispatcherQueueTimerWrapper _timer;

    static readonly string[] FallbackModels = { "gemini-3.1-pro-preview", "gemini-3.5-flash", "gemini-2.5-pro", "gemini-2.5-flash" };

    public MainWindow(AppPaths paths, bool startHidden)
    {
        _paths = paths;
        _server = new ServerManager(paths);
        _options = new AppOptions(paths);
        InitializeComponent();

        Title = "Vertex OpenAI Proxy";
        VersionText.Text = "v" + Updater.CurrentVersion;
        SystemBackdrop = new MicaBackdrop();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "app.ico");
        AppWindow.SetIcon(iconPath);
        TrayIcon.Icon = new System.Drawing.Icon(iconPath);
        TrayIcon.LeftClickCommand = new RelayCommand(ShowWindow);
        TrayIcon.ForceCreate();

        SizeWindow(1040, 820);
        Root.SizeChanged += (_, e) => { ApplyLayout(e.NewSize.Width); UpdateTitleBarRegions(); };
        AppTitleBar.Loaded += (_, _) => UpdateTitleBarRegions();
        GearButton.SizeChanged += (_, _) => UpdateTitleBarRegions();
        Activated += (_, _) => UpdateTitleBarRegions();
        AppTitleBar.SizeChanged += (_, _) => UpdateTitleBarRegions();
        AppWindow.Closing += (_, e) =>
        {
            if (_quitting) return;
            e.Cancel = true;          // X hides to the tray; Quit is in the tray menu
            AppWindow.Hide();
        };

        Banner.Closed += (_, _) => HideBannerSpace();
        _server.Output += (line, _) => EnqueueLog(line);
        _server.StateChanged += _ => DispatcherQueue.TryEnqueue(UpdateStatus);

        try { _options.RepointStartupEntry(); } catch { }
        LoadForm();
        UpdateStatus();
        _timer = new DispatcherQueueTimerWrapper(DispatcherQueue, TimeSpan.FromMilliseconds(400), Tick);

        if (!startHidden) Activate(); else AppWindow.Hide();
        if (_options.AutoStartServer) StartServer();
        if (_options.AutoCheckUpdates) _ = CheckUpdatesAsync(false);
    }

    // ---------- window ----------
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr hwnd);

    void SizeWindow(int w, int h)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var scale = GetDpiForWindow(hwnd) / 96.0;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var pw = Math.Min((int)(w * scale), area.Width - 40);
        var ph = Math.Min((int)(h * scale), area.Height - 40);
        AppWindow.MoveAndResize(new RectInt32(area.X + (area.Width - pw) / 2, area.Y + (area.Height - ph) / 2, pw, ph));
    }

    void ApplyLayout(double width)
    {
        // Server buttons move under the status on narrow windows.
        var inline = width >= 760;
        Grid.SetColumn(ServerButtons, inline ? 1 : 0);
        Grid.SetRow(ServerButtons, inline ? 0 : 1);
        StatusGrid.RowSpacing = inline ? 0 : 12;

        // Connection fields: one row when wide, 2 x 2 when narrow.
        var oneRow = width >= 1100;
        ConnC2.Width = oneRow ? new GridLength(1.4, GridUnitType.Star) : new GridLength(0);
        ConnC3.Width = oneRow ? new GridLength(120) : new GridLength(0);
        ConnGrid.ColumnSpacing = 12;
        Place(ProjectField, 0, 0);
        Place(LocationBox, 0, 1);
        Place(ModelBox, oneRow ? 0 : 1, oneRow ? 2 : 0);
        Place(PortBox, oneRow ? 0 : 1, oneRow ? 3 : 1);
    }

    static void Place(FrameworkElement e, int row, int col)
    {
        Grid.SetRow(e, row);
        Grid.SetColumn(e, col);
    }

    void ShowWindow()
    {
        DispatcherQueue.TryEnqueue(() =>
        {
            AppWindow.Show();
            if (AppWindow.Presenter is OverlappedPresenter p && p.State == OverlappedPresenterState.Minimized) p.Restore();
            Activate();
        });
    }

    async void Quit()
    {
        _quitting = true;
        await _server.StopAsync(CurrentPort);
        TrayIcon.Dispose();
        Application.Current.Exit();
        Environment.Exit(0);
    }

    // ---------- periodic work ----------
    void Tick()
    {
        FlushLog();

        // Commands from SendCommand / a second launch.
        if (File.Exists(_paths.Command))
        {
            string cmd = "";
            try { cmd = File.ReadAllText(_paths.Command).Trim(); File.Delete(_paths.Command); } catch { }
            switch (cmd)
            {
                case "open": ShowWindow(); break;
                case "settings": ShowWindow(); ShowPage(true); break;
                case "restart": _ = RestartServerAsync(); break;
                case "quit": Quit(); break;
            }
        }

        // Fill the model list from the live server once it answers.
        if (_server.IsRunning && !_modelsLoaded && DateTime.Now - _lastModelTry > TimeSpan.FromSeconds(3))
        {
            _lastModelTry = DateTime.Now;
            _ = LoadModelsAsync();
        }

        if (_options.AutoCheckUpdates && DateTime.Now - _lastUpdateCheck > TimeSpan.FromHours(24))
            _ = CheckUpdatesAsync(false);
    }

    // ---------- log ----------
    void EnqueueLog(string line)
    {
        lock (_logLock) _pendingLog.Enqueue(line);
    }

    void FlushLog()
    {
        string[] lines;
        lock (_logLock)
        {
            if (_pendingLog.Count == 0) return;
            lines = _pendingLog.ToArray();
            _pendingLog.Clear();
        }
        foreach (var l in lines) _log.AppendLine(l);
        if (_log.Length > 200_000) _log.Remove(0, _log.Length - 150_000);
        LogBox.Text = _log.ToString();
        LogBox.SelectionStart = LogBox.Text.Length;
        // Keep the newest line in view.
        if (FindScroll(LogBox) is { } sv) sv.ChangeView(null, sv.ScrollableHeight + 1000, null, true);
    }

    static ScrollViewer? FindScroll(DependencyObject o)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(o); i++)
        {
            var c = VisualTreeHelper.GetChild(o, i);
            if (c is ScrollViewer sv) return sv;
            if (FindScroll(c) is { } r) return r;
        }
        return null;
    }

    void Log(string s) => EnqueueLog($"[app] {s}");

    // ---------- form ----------
    string CurrentPort => double.IsNaN(PortBox.Value) ? _saved.Port : ((int)PortBox.Value).ToString();

    static string ComboValue(ComboBox box) =>
        (string.IsNullOrWhiteSpace(box.Text) ? box.SelectedItem as string : box.Text)?.Trim() ?? "";

    ProxySettings FormValues() => new(
        ProjectBox.Password.Trim(),
        ComboValue(LocationBox) is { Length: > 0 } loc ? loc : "global",
        ComboValue(ModelBox) is { Length: > 0 } model ? model : _saved.Model,
        CurrentPort);

    void LoadForm()
    {
        _loading = true;
        _saved = EnvFile.Read(_paths.Env);
        UpdateSummary();
        ProjectBox.Password = _saved.ProjectId;
        SetComboValue(LocationBox, _saved.Location);
        SetModelItems(FallbackModels);
        SetComboValue(ModelBox, _saved.Model);
        PortBox.Value = int.TryParse(_saved.Port, out var p) ? p : 3000;
        BootToggle.IsOn = _options.StartWithWindows;
        AutoServerToggle.IsOn = _options.AutoStartServer;
        UpdateToggle.IsOn = _options.AutoCheckUpdates;
        _loading = false;
        MarkDirty();
        if (!_paths.HasServer) ShowBanner(InfoBarSeverity.Error, "index.js not found", $"Looked upward from {AppContext.BaseDirectory}");
    }

    void SetModelItems(IEnumerable<string> ids)
    {
        var current = ModelBox.SelectedItem as string ?? ModelBox.Text;
        ModelBox.Items.Clear();
        foreach (var id in ids.Distinct()) ModelBox.Items.Add(id);
        SetComboValue(ModelBox, string.IsNullOrEmpty(current) ? _saved.Model : current);
    }

    async Task LoadModelsAsync()
    {
        try
        {
            var ids = await ServerManager.FetchChatModelsAsync(CurrentPort);
            if (ids.Count == 0) return;
            _loading = true;
            SetModelItems(ids);
            _loading = false;
            _modelsLoaded = true;
        }
        catch { /* server still starting; retried by Tick */ }
    }

    void MarkDirty()
    {
        if (_loading) return;
        var dirty = FormValues() != _saved;
        SaveButton.IsEnabled = dirty;
        RevertButton.IsEnabled = dirty;
    }

    void Field_Changed(object sender, RoutedEventArgs e) => MarkDirty();
    void Combo_TextSubmitted(ComboBox sender, ComboBoxTextSubmittedEventArgs args) => DispatcherQueue.TryEnqueue(MarkDirty);
    void Combo_SelectionChanged(object sender, SelectionChangedEventArgs e) => DispatcherQueue.TryEnqueue(MarkDirty);
    void PortBox_ValueChanged(NumberBox sender, NumberBoxValueChangedEventArgs args) => MarkDirty();
    void Revert_Click(object sender, RoutedEventArgs e) => LoadForm();

    async void Save_Click(object sender, RoutedEventArgs e)
    {
        var v = FormValues();
        try { EnvFile.Write(_paths.Env, v); }
        catch (Exception ex) { ShowBanner(InfoBarSeverity.Error, "Could not save .env", ex.Message); return; }
        var oldPort = _saved.Port;
        _saved = v;
        UpdateSummary();
        MarkDirty();
        Log("Settings saved to .env");
        if (_server.IsRunning)
        {
            await _server.StopAsync(oldPort);
            StartServer();
        }
    }

    // ---------- server ----------
    void UpdateStatus()
    {
        var running = _server.IsRunning;
        StatusDot.Fill = new SolidColorBrush(running ? Windows.UI.Color.FromArgb(255, 16, 185, 129) : Windows.UI.Color.FromArgb(255, 160, 160, 160));
        StatusText.Text = running ? "Running" : "Stopped";
        EndpointText.Text = $"http://127.0.0.1:{CurrentPort}/v1";
        StartButton.IsEnabled = !running;
        StopButton.IsEnabled = running;
        RestartButton.IsEnabled = running;
        TrayStartStop.Text = running ? "Stop server" : "Start server";
        TrayIcon.ToolTipText = $"Vertex OpenAI Proxy - {(running ? "running on port " + CurrentPort : "stopped")}";
    }

    void StartServer()
    {
        _modelsLoaded = false;
        if (_server.Start(CurrentPort)) Log($"Server starting on port {CurrentPort}...");
        UpdateStatus();
    }

    async Task RestartServerAsync()
    {
        Log("Restarting server...");
        await _server.StopAsync(CurrentPort);
        StartServer();
    }

    void Start_Click(object sender, RoutedEventArgs e) => StartServer();
    async void Stop_Click(object sender, RoutedEventArgs e) { await _server.StopAsync(CurrentPort); Log("Server stopped."); }
    async void Restart_Click(object sender, RoutedEventArgs e) => await RestartServerAsync();

    void CopyEndpoint_Click(object sender, RoutedEventArgs e)
    {
        var dp = new DataPackage();
        dp.SetText(EndpointText.Text);
        Clipboard.SetContent(dp);
    }

    // ---------- options ----------
    void BootToggle_Toggled(object sender, RoutedEventArgs e)
    {
        if (_loading) return;
        try { _options.StartWithWindows = BootToggle.IsOn; }
        catch (Exception ex) { ShowBanner(InfoBarSeverity.Error, "Could not update the Windows startup entry", ex.Message); }
    }

    void AutoServerToggle_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _options.AutoStartServer = AutoServerToggle.IsOn; }
    void UpdateToggle_Toggled(object sender, RoutedEventArgs e) { if (!_loading) _options.AutoCheckUpdates = UpdateToggle.IsOn; }

    // ---------- updates ----------
    void CheckUpdate_Click(object sender, RoutedEventArgs e) => _ = CheckUpdatesAsync(true);

    async Task CheckUpdatesAsync(bool manual)
    {
        _lastUpdateCheck = DateTime.Now;
        UpdateRing.IsActive = true;
        CheckUpdateButton.IsEnabled = false;
        try
        {
            var rel = await Updater.CheckAsync();
            if (rel == null)
            {
                UpdateStatusText.Text = $"Up to date (v{Updater.CurrentVersion}), checked {DateTime.Now:HH:mm}";
                return;
            }
            _pendingRelease = rel;
            var reason = Updater.NotUpdatableReason(_paths);
            var btn = new Button { Content = $"Install {rel.Version}", Style = (Style)Application.Current.Resources["AccentButtonStyle"], IsEnabled = reason == null };
            btn.Click += async (_, _) => await InstallUpdateAsync();
            ShowBanner(InfoBarSeverity.Informational, $"Update available: {rel.Version}", reason ?? "The app restarts after installing. Your settings are kept.", btn);
            if (!AppWindow.IsVisible && reason == null)
                TrayIcon.ShowNotification("Vertex OpenAI Proxy", $"Version {rel.Version} is available. Open the app to install it.");
        }
        catch (Exception ex)
        {
            UpdateStatusText.Text = "Check failed: " + ex.Message;
            Log("Update check failed: " + ex.Message);
        }
        finally
        {
            UpdateRing.IsActive = false;
            CheckUpdateButton.IsEnabled = true;
        }
    }

    async Task InstallUpdateAsync()
    {
        if (_pendingRelease is not { } rel) return;
        try
        {
            ShowBanner(InfoBarSeverity.Informational, $"Downloading {rel.Version}...", "");
            var progress = new Progress<double>(f => Banner.Message = $"{f:P0}");
            var payload = await Task.Run(() => Updater.DownloadAsync(rel, progress));
            Log($"Update {rel.Version} downloaded; restarting to install.");
            await _server.StopAsync(CurrentPort);
            Updater.Apply(payload, _paths);
            Quit();
        }
        catch (Exception ex)
        {
            ShowBanner(InfoBarSeverity.Error, "Update failed", ex.Message);
        }
    }

    // ---------- misc ----------
    void ShowBanner(InfoBarSeverity sev, string title, string msg, ButtonBase? action = null)
    {
        Banner.Severity = sev;
        Banner.Title = title;
        Banner.Message = msg;
        Banner.ActionButton = action;
        Banner.Visibility = Visibility.Visible;
        Banner.IsOpen = true;
    }

    // A closed InfoBar still takes the grid's row spacing; collapse it fully.
    void HideBannerSpace() => Banner.Visibility = Visibility.Collapsed;

    // ---------- navigation ----------
    void ShowPage(bool settings)
    {
        HomePage.Visibility = settings ? Visibility.Collapsed : Visibility.Visible;
        SettingsPage.Visibility = settings ? Visibility.Visible : Visibility.Collapsed;
    }

    void Gear_Click(object sender, RoutedEventArgs e) => ShowPage(SettingsPage.Visibility != Visibility.Visible);
    void Back_Click(object sender, RoutedEventArgs e) => ShowPage(false);

    void RevealToggle_Changed(object sender, RoutedEventArgs e)
    {
        var show = RevealToggle.IsChecked == true;
        ProjectBox.PasswordRevealMode = show ? PasswordRevealMode.Visible : PasswordRevealMode.Hidden;
        RevealIcon.Glyph = show ? "" : ""; // eye-off / eye
    }

    /// <summary>
    /// The custom title bar is a drag area; the gear button must be a passthrough
    /// region or it never receives clicks.
    /// </summary>
    void UpdateTitleBarRegions()
    {
        if (GearButton.XamlRoot == null || GearButton.ActualWidth == 0) return;
        var scale = GearButton.XamlRoot.RasterizationScale;
        var t = GearButton.TransformToVisual(null).TransformBounds(new Windows.Foundation.Rect(0, 0, GearButton.ActualWidth, GearButton.ActualHeight));
        var rect = new RectInt32((int)(t.X * scale), (int)(t.Y * scale), (int)(t.Width * scale), (int)(t.Height * scale));
        Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(AppWindow.Id)
            .SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Passthrough, new[] { rect });
    }

    // Connection is edited in place on the dashboard; nothing to summarize.
    void UpdateSummary() { }

    /// <summary>Editable ComboBox ignores .Text before it is loaded; select an item instead.</summary>
    static void SetComboValue(ComboBox box, string value)
    {
        if (string.IsNullOrEmpty(value)) return;
        if (!box.Items.Contains(value)) box.Items.Insert(0, value);
        box.SelectedItem = value;
    }

    void ClearLog_Click(object sender, RoutedEventArgs e) { _log.Clear(); LogBox.Text = ""; }
    void OpenFolder_Click(object sender, RoutedEventArgs e) => Process.Start(new ProcessStartInfo("explorer.exe", $"\"{_paths.Root}\"") { UseShellExecute = true });
    void TrayOpen_Click(object sender, RoutedEventArgs e) => ShowWindow();
    async void TrayStartStop_Click(object sender, RoutedEventArgs e)
    {
        if (_server.IsRunning) await _server.StopAsync(CurrentPort); else StartServer();
    }
    void TrayQuit_Click(object sender, RoutedEventArgs e) => Quit();
}

sealed class RelayCommand : System.Windows.Input.ICommand
{
    readonly Action _run;
    public RelayCommand(Action run) => _run = run;
    public event EventHandler? CanExecuteChanged { add { } remove { } }
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => _run();
}

/// <summary>Repeating UI-thread timer.</summary>
sealed class DispatcherQueueTimerWrapper
{
    readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _t;
    public DispatcherQueueTimerWrapper(Microsoft.UI.Dispatching.DispatcherQueue q, TimeSpan interval, Action tick)
    {
        _t = q.CreateTimer();
        _t.Interval = interval;
        _t.Tick += (_, _) => tick();
        _t.Start();
    }
}
