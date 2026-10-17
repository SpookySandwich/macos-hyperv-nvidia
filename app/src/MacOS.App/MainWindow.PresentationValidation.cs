using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;

namespace MacOS.App;
public sealed partial class MainWindow
{
    async Task VerifyPresentation()
    {
        if (verificationRunning) return;
        verificationRunning = true;
        string output = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MacOS", "Validation");
        Directory.CreateDirectory(output);
        var observations = new List<object>();
        var failures = new List<string>();
        try
        {
            var name = new StringBuilder(256);
            if (!GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()), 2, name, 512, out _) || !name.ToString().StartsWith("MacOSValidation-", StringComparison.Ordinal))
                throw new InvalidOperationException("Presentation validation requires a private desktop.");
            foreach (var size in new[] { (720, 480), (1120, 720), (1280, 800) })
            {
                ResizeClientToLogicalSize(size.Item1, size.Item2);
                await SettleLayout();
                var presenter = AppWindow.Presenter as OverlappedPresenter;
                if (presenter is null || !presenter.IsResizable || !presenter.IsMinimizable || !presenter.IsMaximizable)
                    throw new InvalidOperationException("Viewer does not have normal resizable window controls.");
                var point = Viewport.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point());
                if (point.Y < 47 || CaptionBar.Visibility != Microsoft.UI.Xaml.Visibility.Visible)
                    failures.Add("Caption and guest input are not separated.");
                var origin = new WindowPoint(0, 0);
                if (!WindowClientToScreen(hwnd, ref origin)) throw new IOException("Client origin unavailable.");
                int guestY = (int)Math.Ceiling(point.Y * Root.XamlRoot.RasterizationScale);
                var hitTests = new List<object>();
                foreach (int x in new[] { 40, AppWindow.ClientSize.Width / 2, AppWindow.ClientSize.Width - 40 })
                    foreach (int dy in new[] { 2, 10 })
                    {
                        nint location = (nint)(((origin.Y + guestY + dy) & 0xffff) << 16 | ((origin.X + x) & 0xffff));
                        int hit = (int)PresentationSendMessage(hwnd, 0x84, 0, location);
                        hitTests.Add(new { X = x, Y = guestY + dy, Hit = hit });
                        if (hit != 1) failures.Add($"Guest input {x},{guestY + dy} is non-client hit {hit}.");
                    }
                var captions = InputNonClientPointerSource.GetForWindowId(AppWindow.Id).GetRegionRects(NonClientRegionKind.Caption);
                if (captions.Any(r => r.Height > 0 && r.Y + r.Height > guestY)) failures.Add("Caption drag region overlaps the guest.");
                presenter.Maximize(); await SettleLayout();
                if (AppWindow.Presenter.Kind != AppWindowPresenterKind.Overlapped || presenter.State != OverlappedPresenterState.Maximized) failures.Add("Maximize did not remain a normal window.");
                presenter.Restore(); await SettleLayout();
                if (presenter.State != OverlappedPresenterState.Restored) failures.Add("Restore was overridden.");
                presenter.Minimize(); await SettleLayout(); presenter.Restore(); await SettleLayout();
                if (AppWindow.Presenter.Kind != AppWindowPresenterKind.Overlapped) failures.Add("Minimize/restore forced fullscreen.");
                Capture(Path.Combine(output, $"windowed-{size.Item1}-{size.Item2}.png"));
                observations.Add(new { RequestedWidth = size.Item1, RequestedHeight = size.Item2, ActualWidth = Root.ActualWidth, ActualHeight = Root.ActualHeight, Presenter = AppWindow.Presenter.Kind.ToString(), GuestTop = guestY, HitTests = hitTests });
            }
            if (console is not null || guest is not null) failures.Add("Validation created live integration.");
            // Closing with an apparent active/pending session must still detach immediately.
            wasRunning = true; operation = true;
            Closed += (_, _) => File.WriteAllText(Path.Combine(output, "windowed-close.json"), JsonSerializer.Serialize(new { Closed = true, CancellationRequested = lifetime.IsCancellationRequested, LiveIntegrationCreated = console is not null || guest is not null }));
            File.WriteAllText(Path.Combine(output, "chrome-result.json"), JsonSerializer.Serialize(new { Passed = failures.Count == 0, Failures = failures, Observations = observations, LiveIntegrationCreated = false }, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception e) { File.WriteAllText(Path.Combine(output, "chrome-result.json"), JsonSerializer.Serialize(new { Passed = false, Error = e.ToString() })); }
        finally { Close(); }
    }
    [StructLayout(LayoutKind.Sequential)] struct WindowPoint { public int X, Y; public WindowPoint(int x, int y) { X = x; Y = y; } }
    [DllImport("user32.dll", EntryPoint = "ClientToScreen")] static extern bool WindowClientToScreen(nint hwnd, ref WindowPoint point);
    [DllImport("user32.dll", EntryPoint = "SendMessageW")] static extern nint PresentationSendMessage(nint hwnd, uint message, nint wparam, nint lparam);
}
