using System.Runtime.InteropServices;
using MacOS.Core;
namespace MacOS.App;
static class HostDisplay
{
    public static DisplayTarget Read(nint window)
    {
        var screen = System.Windows.Forms.Screen.FromHandle(window);
        var mode = new DevMode { Size = 220 };
        if (EnumDisplaySettings(screen.DeviceName, -1, ref mode))
            return DisplayTarget.Create((int)mode.Width, (int)mode.Height, (int)mode.Frequency);
        return DisplayTarget.Create(screen.Bounds.Width, screen.Bounds.Height, 60);
    }
    [StructLayout(LayoutKind.Explicit, CharSet=CharSet.Unicode, Size=220)]
    struct DevMode
    {
        [FieldOffset(68)] public ushort Size;
        [FieldOffset(172)] public uint Width;
        [FieldOffset(176)] public uint Height;
        [FieldOffset(184)] public uint Frequency;
    }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="EnumDisplaySettingsW")]
    static extern bool EnumDisplaySettings(string device, int index, ref DevMode mode);
}
