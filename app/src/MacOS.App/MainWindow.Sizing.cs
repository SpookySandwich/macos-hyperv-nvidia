using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using System.Runtime.InteropServices;
using Windows.Graphics;

namespace MacOS.App;

public sealed partial class MainWindow
{
    const int MinimumClientWidth = 720, MinimumClientHeight = 480;
    XamlRoot? sizingRoot;
    double WindowScale => Root.XamlRoot?.RasterizationScale ?? GetDpiForWindow(hwnd) / 96.0;

    void ObserveWindowScale()
    {
        if (sizingRoot != Root.XamlRoot)
        {
            if (sizingRoot is not null) sizingRoot.Changed -= WindowScaleChanged;
            sizingRoot = Root.XamlRoot;
            if (sizingRoot is not null) sizingRoot.Changed += WindowScaleChanged;
        }
        UpdateWindowMinimum();
    }

    void WindowScaleChanged(XamlRoot sender, XamlRootChangedEventArgs args) => UpdateWindowMinimum();

    void UpdateWindowMinimum()
    {
        if (AppWindow.Presenter is not OverlappedPresenter presenter) return;
        // XAML uses effective client pixels; the presenter constrains the
        // physical outer window. Include the current non-client frame once.
        var frame = new SizeInt32(AppWindow.Size.Width - AppWindow.ClientSize.Width,
                                 AppWindow.Size.Height - AppWindow.ClientSize.Height);
        int width = (int)Math.Ceiling(MinimumClientWidth * WindowScale) + frame.Width;
        int height = (int)Math.Ceiling(MinimumClientHeight * WindowScale) + frame.Height;
        if (presenter.PreferredMinimumWidth != width) presenter.PreferredMinimumWidth = width;
        if (presenter.PreferredMinimumHeight != height) presenter.PreferredMinimumHeight = height;
    }

    void ResizeClientToLogicalSize(double width, double height)
    {
        // AppWindow sizes are physical pixels, unlike XAML measurements.
        // Fit the work area when a display is smaller than the desired size;
        // loading content remains reachable through its native scroll viewer.
        var work = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var frameWidth = AppWindow.Size.Width - AppWindow.ClientSize.Width;
        var frameHeight = AppWindow.Size.Height - AppWindow.ClientSize.Height;
        // ResizeClient includes the standard caption even when XAML extends
        // into it. The measured outer/client delta describes our actual frame.
        AppWindow.Resize(new SizeInt32(
            Math.Min((int)Math.Ceiling(width * WindowScale) + frameWidth, work.Width),
            Math.Min((int)Math.Ceiling(height * WindowScale) + frameHeight, work.Height)));
    }

    [DllImport("user32.dll")] static extern uint GetDpiForWindow(nint hwnd);
}
