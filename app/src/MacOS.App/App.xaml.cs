using Microsoft.UI.Xaml;
using System.Runtime.InteropServices;
using System.Text;

namespace MacOS.App;
public partial class App : Microsoft.UI.Xaml.Application
{
    MainWindow? window;
    Mutex? instance;
    EventWaitHandle? activation;
    RegisteredWaitHandle? activationWait;
    public App() { InitializeComponent(); }
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        bool verify = Environment.GetCommandLineArgs().Contains("--verify-ui");
        bool verifyChrome = Environment.GetCommandLineArgs().Contains("--verify-chrome");
        // The former dedicated-desktop diagnostic is deliberately retired.
        if (Environment.GetCommandLineArgs().Contains("--prove-desktop-launch")) { Exit(); return; }
        if (verify || verifyChrome)
        {
            var desktop = new StringBuilder(256);
            if (!GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()), 2, desktop, 512, out _) || !desktop.ToString().StartsWith("MacOSValidation-", StringComparison.Ordinal)) { Exit(); return; }
        }
        instance = new Mutex(true, verify || verifyChrome ? "Local\\MacOS.Validation." + Environment.ProcessId : "Local\\MacOS.App", out bool first);
        if (!first)
        {
            if (!verify && !verifyChrome)
            {
                foreach (var process in System.Diagnostics.Process.GetProcessesByName("macOS"))
                {
                    using (process)
                    {
                        try { if (process.Id != Environment.ProcessId && process.MainModule?.FileName == Environment.ProcessPath) AllowSetForegroundWindow((uint)process.Id); } catch { }
                    }
                }
                using var signal = EventWaitHandle.OpenExisting("Local\\MacOS.Activate"); signal.Set();
            }
            Exit(); return;
        }
        window = new MainWindow(verify, verifyChrome);
        if (!verify && !verifyChrome)
        {
            activation = new EventWaitHandle(false, EventResetMode.AutoReset, "Local\\MacOS.Activate");
            activationWait = ThreadPool.RegisterWaitForSingleObject(activation, (_, _) => window.DispatcherQueue.TryEnqueue(async () => await window.EnterSession()), null, Timeout.Infinite, false);
        }
        window.Closed += (_, _) => { activationWait?.Unregister(null); activation?.Dispose(); };
        if (verify || verifyChrome) window.Activate(); else await window.EnterSession();
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern nint FindWindow(string? cls, string title);
    [DllImport("user32.dll")] static extern bool ShowWindow(nint hwnd, int command);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(uint process);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern nint GetThreadDesktop(uint thread);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(nint handle, int index, StringBuilder value, int size, out int needed);
}
