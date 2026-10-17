using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Xaml.Automation;
using Windows.Graphics;
using MacOS.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Windowing;

namespace MacOS.App;
public sealed partial class MainWindow
{
    bool verificationRunning;
    async Task VerifyShell()
    {
        if (verificationRunning) return;
        verificationRunning = true;
        var output = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MacOS", "Validation");
        Directory.CreateDirectory(output);
        DesktopWindowXamlSource? scaledSource = null;
        try
        {
            var name = new StringBuilder(256);
            if (!GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()), 2, name, 512, out _) || !name.ToString().StartsWith("MacOSValidation-", StringComparison.Ordinal))
                throw new InvalidOperationException("UI validation requires a private desktop.");
            var observations = new List<object>();
            double nativeScale = Root.XamlRoot.RasterizationScale;
            // Exercise the actual production minimum, including non-client
            // frame conversion, rather than duplicating its arithmetic.
            UpdateWindowMinimum();
            var presenter = (OverlappedPresenter)AppWindow.Presenter;
            AppWindow.Resize(new SizeInt32(presenter.PreferredMinimumWidth!.Value, presenter.PreferredMinimumHeight!.Value));
            await SettleLayout();
            if (Math.Abs(Root.ActualWidth - 720) > 1 || Math.Abs(Root.ActualHeight - 480) > 1)
                throw new InvalidOperationException($"Minimum client is {Root.ActualWidth}x{Root.ActualHeight}, expected 720x480 effective pixels.");
            await VerifySizeMatrix(nativeScale, "native", output, observations);

            // Real XAML rasterization at additional scales without changing
            // monitor/user settings. Rehost the SAME production visual tree
            // in a supported XAML island on this already-private HWND.
            SetTitleBar(null);
            Content = null;
            scaledSource = new DesktopWindowXamlSource();
            scaledSource.Initialize(AppWindow.Id);
            scaledSource.Content = Root;
            scaledSource.SiteBridge.Show();
            foreach (double scale in new[] { 1.0, 1.5 })
            {
                scaledSource.SiteBridge.OverrideScale = (float)scale;
                scaledSource.SiteBridge.MoveAndResize(new RectInt32(0, 0, AppWindow.ClientSize.Width, AppWindow.ClientSize.Height));
                await SettleLayout();
                ObserveWindowScale();
                if (Math.Abs(Root.XamlRoot.RasterizationScale - scale) > 0.001)
                    throw new InvalidOperationException("XAML island did not adopt the requested rasterization scale.");
                await VerifySizeMatrix(scale, "island", output, observations, scaledSource);
            }
            // Ordinary shell validation must be independent of live VM state.
            // Exercise the production readiness gate with simulated samples;
            // never contact the service, SSH, credential store, or viewer.
            var locked = new GuestReadiness(true, false, true, true, "root", PasswordFieldReady: true);
            var ready = new GuestReadiness(true, true, false, false, MachineConfig.Current.GuestUser, SessionSignedIn: true);
            var samples = new Queue<GuestReadiness?>([null, locked with { BootReady = false }, locked, locked,
                ready with { DesktopReady = false }, ready]);
            int signIns = 0, inspections = 0;
            var result = await new DesktopReadinessGate().WaitAsync(_ =>
            {
                inspections++;
                return Task.FromResult(samples.Dequeue());
            }, _ => { signIns++; return Task.FromResult(true); }, lifetime.Token, _ => Task.CompletedTask);
            if (!result.CanPresent || signIns != 1 || samples.Count != 0 || console is not null || guest is not null)
                throw new InvalidOperationException("Mock readiness scenario failed or created live integration.");
            File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new {
                Desktop = name.ToString(), Layout = observations, Scenario = "mock-readiness",
                SignIns = signIns, Inspections = inspections, Ready = result.CanPresent,
                NativeScale = nativeScale, MinimumEffectiveClient = "720x480", RetryVisible = true,
                LiveIntegrationCreated = false, WindowHandle = hwnd.ToInt64(), ReadOnly = true
            }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(output, "result.json"), JsonSerializer.Serialize(new { Error = ex.ToString(), ReadOnly = true })); }
        finally { scaledSource?.Dispose(); Close(); }
    }

    async Task SettleLayout()
    {
        await Task.Delay(150);
        Root.UpdateLayout();
        await Task.Delay(150);
    }

    bool InBounds(FrameworkElement element, FrameworkElement viewport)
    {
        var point = element.TransformToVisual(viewport).TransformPoint(new Windows.Foundation.Point());
        return element.ActualWidth > 0 && element.ActualHeight > 0 && point.X >= -1 && point.Y >= -1 &&
            point.X + element.ActualWidth <= viewport.ActualWidth + 1 &&
            point.Y + element.ActualHeight <= viewport.ActualHeight + 1;
    }

    async Task VerifySizeMatrix(double scale, string host, string output, List<object> observations,
        DesktopWindowXamlSource? source = null)
    {
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        int fullWidth = (int)((work.Width - (AppWindow.Size.Width - AppWindow.ClientSize.Width)) / scale);
        int fullHeight = (int)((work.Height - (AppWindow.Size.Height - AppWindow.ClientSize.Height)) / scale);
        var sizes = new[] { ("minimum", 720, 480), ("medium", 960, 640), ("full", fullWidth, fullHeight) };
        foreach (var (label, width, height) in sizes)
        {
            ResizeClientToLogicalSize(width, height);
            source?.SiteBridge.MoveAndResize(new RectInt32(0, 0, AppWindow.ClientSize.Width, AppWindow.ClientSize.Height));
            await SettleLayout();
            if (!GetClientRect(hwnd, out var client)) throw new IOException("Client geometry unavailable.");
            if (Math.Abs(Root.ActualWidth * scale - client.Right) > 1 || Math.Abs(Root.ActualHeight * scale - client.Bottom) > 1)
                throw new InvalidOperationException("Effective root and native client geometry disagree.");
            if (Math.Abs(Root.ActualWidth - width) > 1 || Math.Abs(Root.ActualHeight - height) > 1)
                throw new InvalidOperationException($"Requested {width}x{height} effective pixels but received {Root.ActualWidth}x{Root.ActualHeight}.");
            foreach (bool retry in new[] { false, true })
            {
                SetStatus(retry ? "macOS has not reached its unlocked desktop. Your Windows desktop remains active." : "Connecting…", !retry);
                LoadingPanel.ChangeView(null, 0, null, true);
                await SettleLayout();
                if (AutomationProperties.GetAutomationId(MenuButton) != "SessionMenu" || !InBounds(MenuButton, Root) ||
                    !InBounds(LoadingIcon, LoadingPanel) || !InBounds(LoadingTitle, LoadingPanel) || !InBounds(StatusText, LoadingPanel) ||
                    StatusText.IsTextTrimmed || LoadingPanel.ScrollableHeight > 1 ||
                    (retry ? !InBounds(RetryButton, LoadingPanel) || !RetryButton.IsEnabled || Progress.IsActive : !InBounds(Progress, LoadingPanel)))
                    throw new InvalidOperationException($"Clipped or inaccessible {label} {(retry ? "retry" : "loading")} view at {scale * 100}%.");
                string shot = $"{host}-{scale * 100:0}-{label}-{(retry ? "retry" : "loading")}.png";
                Capture(Path.Combine(output, shot));
                observations.Add(new { Host = host, Scale = scale, Size = label, State = retry ? "retry" : "loading",
                    ClientWidth = client.Right, ClientHeight = client.Bottom, EffectiveWidth = Root.ActualWidth, EffectiveHeight = Root.ActualHeight,
                    ViewportWidth = LoadingPanel.ViewportWidth, ViewportHeight = LoadingPanel.ViewportHeight,
                    ScrollableHeight = LoadingPanel.ScrollableHeight, AllContentVisible = true, Screenshot = shot });
            }
        }
        // A long diagnostic must remain reachable even when larger than the
        // viewport. This exercises native scrolling, not merely element flags.
        ResizeClientToLogicalSize(720, 480);
        source?.SiteBridge.MoveAndResize(new RectInt32(0, 0, AppWindow.ClientSize.Width, AppWindow.ClientSize.Height));
        SetStatus(string.Join("\n", Enumerable.Repeat("macOS is still starting. Your Windows desktop remains active.", 16)), false);
        await SettleLayout();
        if (LoadingPanel.ScrollableHeight <= 0) throw new InvalidOperationException("Long status did not provide scroll reachability.");
        LoadingPanel.ChangeView(null, LoadingPanel.ScrollableHeight, null, true);
        await SettleLayout();
        if (!InBounds(RetryButton, LoadingPanel)) throw new InvalidOperationException("Retry cannot be reached after scrolling long status.");
        string overflowShot = $"{host}-{scale * 100:0}-overflow-retry.png";
        Capture(Path.Combine(output, overflowShot));
        observations.Add(new { Host = host, Scale = scale, State = "long-status", ScrollableHeight = LoadingPanel.ScrollableHeight,
            RetryReachable = true, Screenshot = overflowShot });
    }
    void Capture(string path)
    {
        GetWindowRect(hwnd, out var rect);
        using var bitmap = new System.Drawing.Bitmap(rect.Right - rect.Left, rect.Bottom - rect.Top);
        using var graphics = System.Drawing.Graphics.FromImage(bitmap);
        var dc = graphics.GetHdc();
        try { if (!PrintWindow(hwnd, dc, 2)) throw new IOException("Private-window capture is unavailable."); }
        finally { graphics.ReleaseHdc(dc); }
        bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(nint hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool GetClientRect(nint hwnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(nint hwnd, nint dc, uint flags);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern nint GetThreadDesktop(uint thread);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(nint handle, int index, StringBuilder value, int size, out int needed);
}
