using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace MacOS.Core;

public sealed record DesktopInfo(Guid Id, string Name);

// Explorer's internal ABI is kept in this one adapter. Interface layout checked
// against Microsoft TypeAgent and MScholtes/VirtualDesktop (24H2+), then qualified
// on this machine before enabling mutations. Public API handles window placement.
public sealed class VirtualDesktops : IDisposable
{
    readonly IShellServices shell;
    readonly IDesktopManagerInternal manager;
    readonly IDesktopManager placement;
    public VirtualDesktops()
    {
        // Internal COM interfaces are not an OS support contract. A servicing
        // update must be requalified before we mutate Explorer's desktops.
        using (var file = File.OpenRead(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "twinui.pcshell.dll")))
            if (Convert.ToHexString(SHA256.HashData(file)) != "FBA9D85A82D63A9D09958C77A6D27F65C14C213257E99D5ACFAA733F505FDC82")
                throw new NotSupportedException("Windows desktop integration needs a compatibility update for this Windows version. macOS and its GPU assignment have been preserved.");
        shell = (IShellServices)Activator.CreateInstance(Type.GetTypeFromCLSID(new("C2F03A33-21F5-47FA-B4BB-156362A2F239"), true)!)!;
        var service = new Guid("C5E0CDCA-7B6E-41B2-9FC4-D93975CC467B");
        var iid = typeof(IDesktopManagerInternal).GUID;
        manager = (IDesktopManagerInternal)shell.QueryService(ref service, ref iid);
        placement = (IDesktopManager)Activator.CreateInstance(Type.GetTypeFromCLSID(new("AA509086-5CA9-4C25-8F95-589D3C07B48A"), true)!)!;
        // These read-only checks reject a mismatched interface before mutations.
        var desktops = List();
        if (desktops.Count < 1 || desktops.Count != manager.GetCount() || !desktops.Any(d => d.Id == Current))
            throw new NotSupportedException("Windows desktop integration did not pass its compatibility check.");
    }
    public Guid Current { get { var d = manager.GetCurrentDesktop(); try { return d.GetId(); } finally { Release(d); } } }
    public IReadOnlyList<DesktopInfo> List()
    {
        manager.GetDesktops(out var array);
        try
        {
            array.GetCount(out uint count);
            if (count > 1024) throw new NotSupportedException("Unexpected Windows desktop count.");
            List<DesktopInfo> result = [];
            var iid = typeof(IDesktop).GUID;
            for (uint i = 0; i < count; i++)
            {
                array.GetAt(i, ref iid, out object item);
                var d = (IDesktop)item;
                try { result.Add(new(d.GetId(), ReadHString(d.GetName()))); } finally { Release(item); }
            }
            return result;
        }
        finally { Release(array); }
    }
    public Guid Create(string name)
    {
        var d = manager.CreateDesktop();
        try
        {
            Marshal.ThrowExceptionForHR(WindowsCreateString(name, name.Length, out nint value));
            try { manager.SetDesktopName(d, value); } finally { WindowsDeleteString(value); }
            return d.GetId();
        }
        finally { Release(d); }
    }
    public void Switch(Guid id, bool animate = true)
    {
        var d = manager.FindDesktop(ref id);
        try { if (animate) manager.SwitchDesktopWithAnimation(d); else manager.SwitchDesktop(d); }
        finally { Release(d); }
    }
    public void Remove(Guid id, Guid fallback)
    {
        if (id == fallback) throw new ArgumentException("Cannot remove the fallback desktop.");
        var d = manager.FindDesktop(ref id); var f = manager.FindDesktop(ref fallback);
        try { manager.RemoveDesktop(d, f); } finally { Release(f); Release(d); }
    }
    public Guid WindowDesktop(nint hwnd) => placement.GetWindowDesktopId(hwnd);
    public void MoveWindow(nint hwnd, Guid id) => placement.MoveWindowToDesktop(hwnd, ref id);
    static string ReadHString(nint value)
    {
        if (value == 0) return "";
        try { var text = WindowsGetStringRawBuffer(value, out uint length); return Marshal.PtrToStringUni(text, (int)length) ?? ""; }
        finally { WindowsDeleteString(value); }
    }
    static void Release(object value) { if (Marshal.IsComObject(value)) Marshal.ReleaseComObject(value); }
    public void Dispose() { Release(placement); Release(manager); Release(shell); }

    [ComImport, Guid("6D5140C1-7436-11CE-8034-00AA006009FA"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellServices { [return: MarshalAs(UnmanagedType.IUnknown)] object QueryService(ref Guid service, ref Guid iid); }
    [ComImport, Guid("3F07F4BE-B107-441A-AF0F-39D82529072C"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDesktop
    {
        [return: MarshalAs(UnmanagedType.Bool)] bool IsViewVisible(nint view);
        Guid GetId();
        nint GetName();
        nint GetWallpaperPath();
        [return: MarshalAs(UnmanagedType.Bool)] bool IsRemote();
    }
    [ComImport, Guid("53F5CA0B-158F-4124-900C-057158060B27"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDesktopManagerInternal
    {
        int GetCount();
        void MoveViewToDesktop(nint view, IDesktop desktop);
        [return: MarshalAs(UnmanagedType.Bool)] bool CanViewMoveDesktops(nint view);
        IDesktop GetCurrentDesktop();
        void GetDesktops(out IObjects desktops);
        [PreserveSig] int GetAdjacentDesktop(IDesktop from, int direction, out IDesktop desktop);
        void SwitchDesktop(IDesktop desktop);
        void SwitchDesktopAndMoveForegroundView(IDesktop desktop);
        IDesktop CreateDesktop();
        void MoveDesktop(IDesktop desktop, int index);
        void RemoveDesktop(IDesktop desktop, IDesktop fallback);
        IDesktop FindDesktop(ref Guid id);
        void GetDesktopSwitchIncludeExcludeViews(IDesktop desktop, out IObjects include, out IObjects exclude);
        void SetDesktopName(IDesktop desktop, nint name);
        void SetDesktopWallpaper(IDesktop desktop, nint path);
        void UpdateWallpaperPathForAllDesktops(nint path);
        void CopyDesktopState(nint from, nint to);
        void CreateRemoteDesktop(nint path, out IDesktop desktop);
        void SwitchRemoteDesktop(IDesktop desktop, nint type);
        void SwitchDesktopWithAnimation(IDesktop desktop);
        void GetLastActiveDesktop(out IDesktop desktop);
        void WaitForAnimationToComplete();
    }
    [ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDesktopManager
    {
        [return: MarshalAs(UnmanagedType.Bool)] bool IsWindowOnCurrentVirtualDesktop(nint window);
        Guid GetWindowDesktopId(nint window);
        void MoveWindowToDesktop(nint window, ref Guid desktop);
    }
    [ComImport, Guid("92CA9DCD-5622-4BBA-A805-5E9F541BD8C9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IObjects
    {
        void GetCount(out uint count);
        void GetAt(uint index, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object item);
    }
    [DllImport("combase.dll", CharSet = CharSet.Unicode)] static extern int WindowsCreateString(string text, int length, out nint value);
    [DllImport("combase.dll")] static extern nint WindowsGetStringRawBuffer(nint value, out uint length);
    [DllImport("combase.dll")] static extern int WindowsDeleteString(nint value);
}
