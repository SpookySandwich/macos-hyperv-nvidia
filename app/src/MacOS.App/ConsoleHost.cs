using AxMSTSCLib;
using MacOS.Core;
using MSTSCLib;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Forms = System.Windows.Forms;

namespace MacOS.App;
// Host the Windows RDP ActiveX control itself; no reparented vmconnect process.
sealed class ConsoleHost : IDisposable
{
    readonly Forms.Panel panel = new() { BackColor = System.Drawing.Color.Black };
    readonly AxMsRdpClient9NotSafeForScripting rdp = new();
    public event Action? Connected;
    public event Action<int>? Disconnected;
    public event Action<string>? Notice;
    public string Diagnostic { get; private set; } = "Created";
    public int ConnectionState => rdp.Connected;
    bool ready, hidden, disposed;
    int remoteWidth, remoteHeight;
    uint zoomPercent, attemptedZoomPercent;
    public ConsoleHost(nint parent)
    {
        SetWindowLongPtr(parent, -16, (nint)(GetWindowLongPtr(parent, -16).ToInt64() | 0x02000000L));
        for (var sibling = GetWindow(parent, 5); sibling != 0; sibling = GetWindow(sibling, 2))
            SetWindowLongPtr(sibling, -16, (nint)(GetWindowLongPtr(sibling, -16).ToInt64() | 0x04000000L));
        panel.CreateControl();
        SetParent(panel.Handle, parent);
        var style = GetWindowLongPtr(panel.Handle, -16).ToInt64();
        SetWindowLongPtr(panel.Handle, -16, (nint)((style | 0x46000000L) & ~0x80000000L));
        ((ISupportInitialize)rdp).BeginInit();
        rdp.Dock = Forms.DockStyle.Fill;
        panel.Controls.Add(rdp);
        ((ISupportInitialize)rdp).EndInit();
        rdp.CreateControl();
        rdp.OnConnecting += (_, _) => Diagnostic = "Connecting";
        rdp.OnConnected += (_, _) => { Diagnostic = "Connected"; ready = true; zoomPercent = attemptedZoomPercent = 0; FitVideo(); if (!hidden) panel.Show(); Connected?.Invoke(); };
        rdp.OnRemoteDesktopSizeChange += (_, e) => { remoteWidth = e.width; remoteHeight = e.height; attemptedZoomPercent = 0; FitVideo(); };
        rdp.OnDisconnected += (_, e) => { Diagnostic = $"Disconnected {e.discReason}; extended {rdp.ExtendedDisconnectReason}"; ready = false; if (!disposed) Disconnected?.Invoke(e.discReason); };
        rdp.OnFatalError += (_, e) => Diagnostic = $"Fatal error {e.errorCode}";
        panel.Hide();
    }
    public void Connect()
    {
        rdp.Server = "localhost"; rdp.DesktopWidth = 1920; rdp.DesktopHeight = 1080; rdp.ColorDepth = 32;
        rdp.AdvancedSettings7.RDPPort = 2179;
        rdp.AdvancedSettings7.PCB = Protocol.VmId;
        // SmartSizing does not scale this basic Hyper-V framebuffer path.
        // Use the supported ZoomLevel property; the two modes are exclusive.
        rdp.AdvancedSettings7.SmartSizing = false;
        rdp.AdvancedSettings7.EnableCredSspSupport = true;
        rdp.AdvancedSettings7.AuthenticationServiceClass = "Microsoft Virtual Console Service";
        rdp.AdvancedSettings7.RedirectClipboard = false;
        rdp.AdvancedSettings7.RedirectDrives = false;
        rdp.AdvancedSettings7.RedirectPrinters = false;
        rdp.AdvancedSettings7.RedirectSmartCards = false;
        rdp.AdvancedSettings7.EnableAutoReconnect = true;
        rdp.AdvancedSettings7.MaxReconnectAttempts = 3;
        rdp.AdvancedSettings7.GrabFocusOnConnect = false;
        rdp.SecuredSettings2.KeyboardHookMode = 0; // Windows handles its own desktop-switching shortcuts.
        var nonScriptable = (IMsRdpClientNonScriptable5)(rdp.GetOcx() ?? throw new InvalidOperationException("The Windows console control is unavailable."));
        nonScriptable.PromptForCredentials = false;
        nonScriptable.AllowPromptingForCredentials = false;
        nonScriptable.EnableCredSspSupport = true;
        nonScriptable.NegotiateSecurityLayer = false;
        rdp.AdvancedSettings7.AuthenticationLevel = 0;
        var extended = (IMsRdpExtendedSettings)rdp.GetOcx()!;
        object enabled = true;
        extended.set_Property("DisableCredentialsDelegation", ref enabled);
        extended.set_Property("EnableFrameBufferRedirection", ref enabled);
        // VMConnect uses these local-only settings: Windows authenticates the
        // caller's token without forwarding or storing its credentials.
        hidden = false; panel.Show();
        rdp.Connect();
    }
    public void Position(int x, int y, int width, int height)
    {
        if (width <= 0 || height <= 0) return;
        SetWindowPos(panel.Handle, 0, x, y, width, height, 0x0010);
        FitVideo();
        if (ready && !hidden) panel.Show();
    }
    public void Hide() { hidden = true; panel.Hide(); }
    public void Show() { hidden = false; if (ready) panel.Show(); }
    public void Focus() { if (ready && !hidden) rdp.Focus(); }
    void FitVideo()
    {
        if (!ready || disposed) return;
        uint next = ViewerGeometry.FitPercent(panel.ClientSize.Width, panel.ClientSize.Height, remoteWidth, remoteHeight);
        if (next == 0 || next == zoomPercent || next == attemptedZoomPercent) return;
        // A failed property must not loop through Notice -> layout -> Position.
        attemptedZoomPercent = next;
        try
        {
            object value = next;
            ((IMsRdpExtendedSettings)rdp.GetOcx()!).set_Property("ZoomLevel", ref value);
            zoomPercent = next;
        }
        catch (COMException ex) { Diagnostic = $"Display scaling failed ({ex.HResult:X8})"; Notice?.Invoke("The guest display could not fit the window. Enlarge the window to see the edges."); }
    }
    public object LayoutDiagnostic()
    {
        var children = new List<object>();
        var parent = GetParent(panel.Handle);
        for (var child = GetWindow(parent, 5); child != 0; child = GetWindow(child, 2))
        {
            var name = new System.Text.StringBuilder(256); GetClassName(child, name, 256);
            children.Add(new { Handle = child.ToInt64(), Class = name.ToString(), Style = GetWindowLongPtr(child, -16).ToInt64().ToString("X"), Visible = IsWindowVisible(child) });
        }
        return new { Panel = panel.Bounds.ToString(), Rdp = rdp.Bounds.ToString(), RemoteWidth = remoteWidth, RemoteHeight = remoteHeight, ZoomPercent = zoomPercent, Visible = IsWindowVisible(panel.Handle), NativeParent = parent.ToInt64(), PanelHandle = panel.Handle.ToInt64(), Children = children };
    }
    public void Capture(string path)
    {
        using var image = new System.Drawing.Bitmap(Math.Max(1, panel.Width), Math.Max(1, panel.Height));
        using var graphics = System.Drawing.Graphics.FromImage(image);
        var dc = graphics.GetHdc();
        try { PrintWindow(panel.Handle, dc, 2); } finally { graphics.ReleaseHdc(dc); }
        image.Save(path, System.Drawing.Imaging.ImageFormat.Png);
    }
    // Read a small client-region tile for the isolated cadence test. A changing
    // pixel is evidence of a delivered frame; timer ticks alone are not.
    public int CaptureMarker(System.Drawing.Bitmap tile, System.Drawing.Graphics graphics)
    {
        var dc = graphics.GetHdc();
        try {
            SetViewportOrgEx(dc, -(panel.Width / 2), -(panel.Height / 2), 0);
            if (!PrintWindow(panel.Handle, dc, 2)) return -1;
        } finally { graphics.ReleaseHdc(dc); }
        return tile.GetPixel(0, 0).ToArgb();
    }
    public void Dispose() { disposed = true; try { if (rdp.Connected != 0) rdp.Disconnect(); } catch { } panel.Dispose(); }
    [DllImport("user32.dll")] static extern nint SetParent(nint child, nint parent);
    [DllImport("user32.dll")] static extern nint GetParent(nint child);
    [DllImport("user32.dll")] static extern nint GetWindow(nint window, uint command);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(nint window, System.Text.StringBuilder name, int capacity);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(nint child);
    [DllImport("user32.dll")] static extern bool PrintWindow(nint hwnd, nint dc, uint flags);
    [DllImport("gdi32.dll")] static extern bool SetViewportOrgEx(nint dc, int x, int y, nint previous);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern nint GetWindowLongPtr(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern nint SetWindowLongPtr(nint window, int index, nint value);
    [DllImport("user32.dll")] static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
}
