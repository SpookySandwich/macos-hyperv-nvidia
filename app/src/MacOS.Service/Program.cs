using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.ServiceProcess;
using System.Text;
using System.Text.Json;
using MacOS.Core;

namespace MacOS.Service;
static class Program
{
    static void Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--request" && Protocol.Allowed(args[1]))
        {
            var reply = new ServiceClient().SendAsync(args[1]).GetAwaiter().GetResult();
            Console.WriteLine(JsonSerializer.Serialize(reply)); Environment.ExitCode = reply.Success ? 0 : 1; return;
        }
        if (args.SequenceEqual(new[] { "--inspect" }))
        {
            Console.WriteLine(JsonSerializer.Serialize(new PowerShellMachine().InspectAsync(default).GetAwaiter().GetResult()));
            return;
        }
        ServiceBase.Run(new SessionService());
    }
}
sealed class SessionService : ServiceBase
{
    readonly CancellationTokenSource cancellation = new();
    readonly SessionController controller;
    readonly string data = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "MacOS");
    Task? server;
    public SessionService()
    {
        ServiceName = Protocol.ServiceName; CanShutdown = true; CanStop = true;
        controller = new(new PowerShellMachine(), Journal);
    }
    void Journal(string message)
    {
        try { File.AppendAllText(Path.Combine(data, "session.log"), $"{DateTimeOffset.Now:o} {message}\n"); } catch { }
    }
    protected override void OnStart(string[] args)
    {
        var config = JsonSerializer.Deserialize<HostConfig>(File.ReadAllText(Path.Combine(data, "host.json")), Protocol.Json)
            ?? throw new InvalidDataException("Missing installation configuration.");
        _ = new SecurityIdentifier(config.OwnerSid);
        server = Task.Run(() => Serve(config.OwnerSid, cancellation.Token));
        _ = Task.Run(() => MonitorBattery(cancellation.Token));
        Journal("Service started; existing VM ownership retained.");
    }
    protected override void OnStop() { cancellation.Cancel(); Journal("Service stopped; running VM ownership retained."); }
    protected override void OnShutdown()
    {
        // Best effort only: Windows may impose a shorter shutdown deadline.
        try { controller.ExecuteAsync("stop").Wait(TimeSpan.FromSeconds(15)); } catch { }
        cancellation.Cancel();
    }
    async Task Serve(string owner, CancellationToken ct)
    {
        var security = new PipeSecurity();
        security.SetAccessRuleProtection(true, false);
        foreach (var sid in new[] { owner, "S-1-5-18", "S-1-5-32-544" })
            security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(sid), PipeAccessRights.FullControl, AccessControlType.Allow));
        security.AddAccessRule(new PipeAccessRule(new SecurityIdentifier("S-1-5-2"), PipeAccessRights.FullControl, AccessControlType.Deny));
        while (!ct.IsCancellationRequested)
        {
            var pipe = NamedPipeServerStreamAcl.Create(Protocol.Pipe, PipeDirection.InOut, 8, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous, 4096, 4096, security);
            try { await pipe.WaitForConnectionAsync(ct); _ = Handle(pipe, ct); }
            catch { pipe.Dispose(); if (!ct.IsCancellationRequested) await Task.Delay(1000, ct); }
        }
    }
    async Task Handle(NamedPipeServerStream pipe, CancellationToken serviceToken)
    {
        using (pipe)
        using (var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true))
        using (var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true })
        {
            try
            {
                using var deadline = CancellationTokenSource.CreateLinkedTokenSource(serviceToken);
                deadline.CancelAfter(TimeSpan.FromSeconds(5));
                var chars = new List<char>();
                var buffer = new char[1];
                while (chars.Count < 8192 && await reader.ReadAsync(buffer, deadline.Token) == 1 && buffer[0] != '\n') chars.Add(buffer[0]);
                if (chars.Count >= 8192) return;
                var request = JsonSerializer.Deserialize<Request>(new string(chars.ToArray()), Protocol.Json);
                // Request completion is independent of a disconnected/crashed client.
                SessionReply reply;
                if (request?.Action == "wake")
                {
                    try { await new PowerShellMachine().WakeSignInAsync(serviceToken); reply = new(true, "Opening the macOS sign-in screen…"); }
                    catch { reply = new(false, "Could not open the macOS sign-in screen. No credential was sent."); }
                    request = null;
                }
                else if (request?.Action == "unlock")
                {
                    if (string.IsNullOrEmpty(request.Secret) || request.Secret.Length > 512 || request.Secret.Contains('\n') || request.Secret.Contains('\r'))
                        reply = new(false, "The stored macOS sign-in credential is unavailable.");
                    else
                    {
                        try { await new PowerShellMachine().UnlockAsync(request.Secret, serviceToken); reply = new(true, "Signing in to macOS…"); }
                        catch { reply = new(false, "macOS sign-in input failed. No credential was saved or logged."); }
                    }
                    request = null;
                }
                else reply = await controller.ExecuteAsync(request?.Action ?? "invalid", serviceToken);
                await writer.WriteLineAsync(JsonSerializer.Serialize(reply));
            }
            catch (Exception ex) { Journal("Client: " + ex.Message); }
        }
    }
    async Task MonitorBattery(CancellationToken ct)
    {
        bool triggered = false;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (GetSystemPowerStatus(out var power))
                {
                    if (power.ACLineStatus == 1 || power.BatteryLifePercent > 15) triggered = false;
                    if (!triggered && power.ACLineStatus == 0 && power.BatteryLifePercent <= 12)
                    {
                        var state = await controller.ExecuteAsync("status", ct);
                        if (BatteryPolicy.ShouldShutdown(true, power.BatteryLifePercent, state.Machine?.VmState == "Running"))
                        {
                            triggered = true; Journal("Low battery: requesting graceful macOS shutdown.");
                            var reply = await controller.ExecuteAsync("stop", ct);
                            Journal(reply.Message);
                            if (!reply.Success) triggered = false;
                        }
                    }
                }
                await Task.Delay(TimeSpan.FromSeconds(10), ct);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) { Journal("Battery monitor: " + ex.Message); await Task.Delay(10000, ct); }
        }
    }
    [StructLayout(LayoutKind.Sequential)] struct PowerStatus { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public uint BatteryLifeTime, BatteryFullLifeTime; }
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out PowerStatus status);
}

sealed class PowerShellMachine : IMachine
{
    async Task<string> Run(string action, CancellationToken ct, string? secret = null)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "powershell.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, RedirectStandardInput = secret is not null };
        if (secret is not null) start.StandardInputEncoding = new UTF8Encoding(false);
        foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", Path.Combine(AppContext.BaseDirectory, "host.ps1"), "-Action", action }) start.ArgumentList.Add(a);
        using var process = Process.Start(start) ?? throw new IOException("Could not start Hyper-V management.");
        var output = process.StandardOutput.ReadToEndAsync(ct);
        var errors = process.StandardError.ReadToEndAsync(ct);
        if (secret is not null) { await process.StandardInput.WriteLineAsync(secret.AsMemory(), ct); process.StandardInput.Close(); secret = null; }
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(130));
        try { await process.WaitForExitAsync(deadline.Token); }
        catch { if (!process.HasExited) process.Kill(true); throw; }
        var text = await output; var error = await errors;
        if (process.ExitCode != 0) throw new InvalidOperationException(error.Trim());
        return text.Trim();
    }
    public async Task<MachineState> InspectAsync(CancellationToken ct) => JsonSerializer.Deserialize<MachineState>(await Run("Inspect", ct), Protocol.Json) ?? throw new InvalidDataException("Invalid Hyper-V state.");
    public async Task AssignAsync(CancellationToken ct) => _ = await Run("Assign", ct);
    public async Task StartAsync(CancellationToken ct) => _ = await Run("Start", ct);
    public async Task ShutdownAsync(CancellationToken ct) => _ = await Run("Shutdown", ct);
    public async Task ReturnAsync(CancellationToken ct) => _ = await Run("Return", ct);
    public async Task UnlockAsync(string secret, CancellationToken ct) => _ = await Run("Unlock", ct, secret);
    public async Task WakeSignInAsync(CancellationToken ct) => _ = await Run("WakeSignIn", ct);
}
