using MacOS.Core;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using System.Diagnostics;

namespace MacOS.App;
public sealed partial class MainWindow : Window
{
    readonly ServiceClient service = new();
    readonly CancellationTokenSource lifetime = new();
    readonly DispatcherTimer monitor = new() { Interval = TimeSpan.FromSeconds(5) };
    readonly nint hwnd;
    readonly TaskCompletionSource loaded = new(TaskCreationOptions.RunContinuationsAsynchronously);
    readonly string preferencesPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MacOS", "viewer.json");
    DisplayTarget displayTarget;
    ConsoleHost? console;
    GuestConnection? guest;
    ClipboardBridge? clipboard;
    AudioSession? audio;
    TaskCompletionSource? displayConnected;
    Task? launchTask;
    bool operation, monitorBusy, wasRunning, stopping, sessionReady, windowActive;

    public MainWindow(bool verify = false, bool verifyChrome = false)
    {
        displayTarget = ViewerPreferences.Load(preferencesPath);
        InitializeComponent();
        hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        SetWindowedPresentation();
        ResizeClientToLogicalSize(800, 480);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "macOS.ico"));
        UpdateWindowMinimum();
        AppWindow.Changed += (_, args) => { if (args.DidPresenterChange) UpdateWindowMinimum(); };
        Viewport.SizeChanged += (_, _) => PositionConsole();
        Root.Loaded += async (_, _) => { ObserveWindowScale(); loaded.TrySetResult(); if (verify) await VerifyShell(); else if (verifyChrome) await VerifyPresentation(); };
        Activated += (_, e) =>
        {
            windowActive = e.WindowActivationState != WindowActivationState.Deactivated;
            clipboard?.SetActive(windowActive && sessionReady && !operation);
        };
        // Closing a viewer disconnects it. Only the explicit menu command stops the VM.
        Closed += (_, _) => { lifetime.Cancel(); monitor.Stop(); audio?.Dispose(); clipboard?.Dispose(); guest?.Dispose(); console?.Dispose(); };
        monitor.Tick += async (_, _) => await Monitor();
        if (!verify && !verifyChrome) monitor.Start();
    }
    public Task EnterSession()
    {
        if (AppWindow.Presenter is OverlappedPresenter presenter && presenter.State == OverlappedPresenterState.Minimized) presenter.Restore();
        Activate();
        if (operation) return launchTask ?? Task.CompletedTask;
        if (sessionReady && console?.ConnectionState == 1) return Task.CompletedTask;
        return launchTask = EnterSessionCore();
    }
    async Task EnterSessionCore()
    {
        operation = true; sessionReady = false;
        SetStatus("Preparing macOS…");
        try
        {
            await loaded.Task.WaitAsync(lifetime.Token);
            var reply = await service.SendAsync("start", lifetime.Token);
            if (!reply.Success) throw new InvalidOperationException(reply.Message);
            wasRunning = true;
            guest ??= new GuestConnection(service);
            if (console?.ConnectionState != 1)
            {
                ConnectConsole();
                await displayConnected!.Task.WaitAsync(TimeSpan.FromSeconds(30), lifetime.Token);
            }
            await guest.WaitReadyAsync(lifetime.Token);
            try { await guest.MatchDisplayAsync(displayTarget, lifetime.Token); }
            catch (Exception ex) when (ex is not OperationCanceledException) { ShowNotice(ex.Message); }
            await guest.WaitReadyAsync(lifetime.Token);
            if (clipboard is null)
            {
                try { await guest.EnsureBridgeAsync(lifetime.Token); clipboard = new ClipboardBridge(guest, ShowNotice); clipboard.Start(); }
                catch (Exception ex) when (ex is not OperationCanceledException) { Debug.WriteLine(ex); }
            }
            sessionReady = true;
            LoadingPanel.Visibility = Visibility.Collapsed;
            console!.Show(); PositionConsole();
            clipboard?.SetActive(windowActive);
            if (audio is null) { audio = new AudioSession(guest, message => DispatcherQueue.TryEnqueue(() => ShowNotice(message))); audio.Start(); }
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception ex)
        {
            console?.Hide();
            audio?.Dispose(); audio = null;
            clipboard?.Dispose(); clipboard = null;
            guest?.Dispose(); guest = null;
            SetStatus(ex.Message, false);
        }
        finally { operation = false; }
    }
    void SetStatus(string text, bool busy = true)
    {
        StatusText.Text = text; Progress.IsActive = busy; Progress.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        LoadingPanel.Visibility = Visibility.Visible; RetryButton.Visibility = busy ? Visibility.Collapsed : Visibility.Visible;
    }
    void ShowNotice(string message) { Notice.Message = message; Notice.IsOpen = !string.IsNullOrEmpty(message); PositionConsole(); }
    void ConnectConsole()
    {
        displayConnected = new(TaskCreationOptions.RunContinuationsAsynchronously);
        console?.Dispose(); console = new ConsoleHost(hwnd);
        console.Notice += message => DispatcherQueue.TryEnqueue(() => ShowNotice(message));
        console.Connected += () => DispatcherQueue.TryEnqueue(() => { guest?.ResetDisplayMatch(); displayConnected.TrySetResult(); PositionConsole(); });
        console.Disconnected += reason => DispatcherQueue.TryEnqueue(() =>
        {
            displayConnected.TrySetException(new IOException($"The display disconnected ({reason})."));
            if (!stopping && !lifetime.IsCancellationRequested) { sessionReady = false; clipboard?.SetActive(false); console?.Hide(); SetStatus($"The display disconnected ({reason}). macOS keeps running.", false); }
        });
        PositionConsole(); console.Connect(); console.Hide();
    }
    void PositionConsole()
    {
        if (console is null || Root.XamlRoot is null) return;
        var p = Viewport.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point());
        var scale = Root.XamlRoot.RasterizationScale;
        console.Position((int)(p.X * scale), (int)(p.Y * scale), (int)(Viewport.ActualWidth * scale), (int)(Viewport.ActualHeight * scale));
    }
    async Task StopSession()
    {
        if (operation) return;
        operation = stopping = true; sessionReady = false;
        clipboard?.Dispose(); clipboard = null; console?.Hide();
        SetStatus("Shutting down macOS…");
        try
        {
            if (audio is not null) { await audio.StopAsync(); audio = null; }
            var reply = await service.SendAsync("stop", lifetime.Token);
            if (!reply.Success) throw new InvalidOperationException(reply.Message);
            wasRunning = false; SetStatus("macOS is shut down.", false);
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception ex) { SetStatus(ex.Message, false); }
        finally { operation = stopping = false; }
    }
    async Task Monitor()
    {
        if (monitorBusy || operation || lifetime.IsCancellationRequested) return;
        monitorBusy = true;
        try
        {
            var reply = await service.SendAsync("status", lifetime.Token);
            if (wasRunning && reply.Machine?.VmState == "Off")
            {
                wasRunning = sessionReady = false;
                clipboard?.SetActive(false); console?.Hide(); audio?.Dispose(); audio = null;
                SetStatus("macOS is shut down.", false);
            }
        }
        catch { /* The next explicit request reports service failures. */ }
        finally { monitorBusy = false; }
    }
    async void ResolutionClick(object sender, RoutedEventArgs e)
    {
        if (operation || !sessionReady || guest is null) return;
        var target = ((Microsoft.UI.Xaml.Controls.MenuFlyoutItem)sender).Tag as string == "1080" ? ViewerPreferences.FullHD : ViewerPreferences.Default;
        operation = true;
        try
        {
            await guest.MatchDisplayAsync(target, lifetime.Token);
            ViewerPreferences.Save(preferencesPath, target); displayTarget = target; ShowNotice("");
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception ex) { ShowNotice(ex.Message); }
        finally { operation = false; }
    }
    async void RetryClick(object sender, RoutedEventArgs e) => await EnterSession();
    async void ShutdownClick(object sender, RoutedEventArgs e) => await StopSession();
    void DiagnosticsClick(object sender, RoutedEventArgs e) => Process.Start(new ProcessStartInfo("explorer.exe", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "MacOS")) { UseShellExecute = true });
}
