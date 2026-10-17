using MacOS.Core;
using Microsoft.UI.Xaml;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using Forms = System.Windows.Forms;

namespace MacOS.App;
sealed class ClipboardBridge(GuestConnection guest, Action<string> notice) : IDisposable
{
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(750) };
    readonly CancellationTokenSource lifetime = new();
    bool busy, active = true, entering = true, initialized, warned;
    uint hostRevision;
    long guestRevision;
    public void SetActive(bool value) { entering |= value && !active; active = value; }
    public void Start() { timer.Tick += Tick; timer.Start(); }
    async void Tick(object? sender, object e)
    {
        if (busy || !active || lifetime.IsCancellationRequested) return;
        busy = true;
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); timeout.CancelAfter(TimeSpan.FromSeconds(5));
            var before = GetClipboardSequenceNumber();
            var remote = await guest.ClipboardAsync(new { action = "read", revision = initialized ? guestRevision : -1 }, timeout.Token);
            if (!remote.Supported) return;
            if (!initialized)
            {
                // Starting the app must not overwrite either existing clipboard.
                hostRevision = before; guestRevision = remote.Revision; initialized = true; return;
            }
            var direction = ClipboardPolicy.Direction(before != hostRevision, remote.Revision != guestRevision, entering);
            entering = false;
            if (direction == "toGuest")
            {
                var local = ReadHost();
                if (ClipboardPolicy.Valid(local))
                {
                    var result = await guest.ClipboardAsync(new { action = "write", text = local.Text, png = local.Png }, timeout.Token);
                    guestRevision = result.Revision;
                }
                hostRevision = before;
            }
            else if (direction == "toHost" && GetClipboardSequenceNumber() == before)
            {
                if (ClipboardPolicy.Valid(remote)) { WriteHost(remote); hostRevision = GetClipboardSequenceNumber(); }
                guestRevision = remote.Revision;
            }
            warned = false;
        }
        catch (OperationCanceledException) when (lifetime.IsCancellationRequested) { }
        catch (Exception) { if (!warned && !lifetime.IsCancellationRequested) { warned = true; notice("Clipboard sync is reconnecting. The macOS session is still available."); } }
        finally { busy = false; }
    }
    static ClipboardSnapshot ReadHost()
    {
        string? text = Forms.Clipboard.ContainsText() ? Forms.Clipboard.GetText() : null;
        string? png = null;
        if (Forms.Clipboard.ContainsImage())
        {
            using var image = Forms.Clipboard.GetImage();
            if (image is not null) { using var ms = new MemoryStream(); image.Save(ms, System.Drawing.Imaging.ImageFormat.Png); if (ms.Length <= ClipboardPolicy.MaximumBytes) png = Convert.ToBase64String(ms.ToArray()); }
        }
        return new(0, text, png, text is not null || png is not null);
    }
    static void WriteHost(ClipboardSnapshot snapshot)
    {
        if (snapshot.Text is null && snapshot.Png is null) return;
        var data = new Forms.DataObject();
        if (snapshot.Text is not null) data.SetText(snapshot.Text);
        if (snapshot.Png is not null)
        {
            var bytes = Convert.FromBase64String(snapshot.Png);
            using var ms = new MemoryStream(bytes);
            using var image = System.Drawing.Image.FromStream(ms);
            using var bitmap = new System.Drawing.Bitmap(image);
            data.SetImage(bitmap); Forms.Clipboard.SetDataObject(data, true); return;
        }
        Forms.Clipboard.SetDataObject(data, true);
    }
    public void Dispose() { timer.Stop(); lifetime.Cancel(); }
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
}
