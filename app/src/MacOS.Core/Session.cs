using System.Text.Json;

namespace MacOS.Core;

public sealed record MachineState(string VmState, bool GpuAssigned, bool GpuAvailable, bool HostHealthy, string? Address = null);
public sealed record SessionReply(bool Success, string Message, MachineState? Machine = null);
public sealed record Request(string Action, string? Secret = null);
public sealed record HostConfig(string OwnerSid, string OwnerAccount);
public static class Protocol
{
    public const string Pipe = "MacOS.Session.v1";
    public const string ServiceName = "MacOSSession";
    public static string VmId => MachineConfig.Current.VmId;
    public static readonly JsonSerializerOptions Json = new() { PropertyNameCaseInsensitive = true };
    public static bool SessionAction(string action) => action is "status" or "start" or "stop";
    public static bool Allowed(string action) => SessionAction(action) || action is "unlock" or "wake";
}

public interface IMachine
{
    Task<MachineState> InspectAsync(CancellationToken ct);
    Task AssignAsync(CancellationToken ct);
    Task StartAsync(CancellationToken ct);
    Task ShutdownAsync(CancellationToken ct);
    Task ReturnAsync(CancellationToken ct);
}

// The lifecycle belongs to the service, never to a window/process lifetime.
public sealed class SessionController(IMachine machine, Action<string>? journal = null)
{
    readonly SemaphoreSlim gate = new(1);
    public string Activity { get; private set; } = "";
    public async Task<SessionReply> ExecuteAsync(string action, CancellationToken ct = default)
    {
        if (!Protocol.SessionAction(action)) return new(false, "Unknown operation.");
        if (action == "status")
        {
            try { return new(true, Activity, await machine.InspectAsync(ct)); }
            catch (Exception ex) { return new(false, ex.Message); }
        }
        if (!await gate.WaitAsync(0, ct)) return new(false, "A macOS operation is already in progress.");
        try
        {
            var state = await machine.InspectAsync(ct);
            if (action == "start")
            {
                if (state.VmState == "Running")
                {
                    if (!state.GpuAssigned) throw new InvalidOperationException("macOS is running without the 4060. Shut it down before starting a GPU session.");
                    return new(true, "Connecting to macOS…", state);
                }
                if (state.VmState != "Off") throw new InvalidOperationException("Wait for macOS to finish shutting down.");
                if (state.GpuAssigned || state.GpuAvailable)
                {
                    // An off guest can retain a device after an interrupted
                    // shutdown. Complete the ownership transition before a
                    // fresh assignment so the Windows driver resets the GPU.
                    // The backend verifies Off again before detaching anything.
                    Activity = "Preparing the RTX 4060…"; journal?.Invoke("RecoveringGpu");
                    await machine.ReturnAsync(ct);
                }
                Activity = "Preparing the RTX 4060…"; journal?.Invoke("Assigning");
                await machine.AssignAsync(ct);
                Activity = "Starting macOS…"; journal?.Invoke("Starting");
                try { await machine.StartAsync(ct); }
                catch
                {
                    // Never reclaim hardware from a guest that actually started.
                    if ((await machine.InspectAsync(CancellationToken.None)).VmState == "Off")
                        await machine.ReturnAsync(CancellationToken.None);
                    throw;
                }
                state = await machine.InspectAsync(ct);
                if (state.VmState != "Running" || !state.GpuAssigned) throw new InvalidOperationException("macOS did not start with the 4060.");
                journal?.Invoke("GuestOwnsGpu");
                return new(true, "Connecting to macOS…", state);
            }
            Activity = "Shutting down macOS…"; journal?.Invoke("ShuttingDown");
            if (state.VmState is "Running" or "Stopping") await machine.ShutdownAsync(ct);
            state = await machine.InspectAsync(ct);
            if (state.VmState != "Off") throw new InvalidOperationException("macOS has not shut down. The GPU remains assigned; no work was discarded.");
            Activity = "Returning the RTX 4060…";
            await machine.ReturnAsync(ct);
            state = await machine.InspectAsync(ct);
            if (state.GpuAssigned || state.GpuAvailable || !state.HostHealthy) throw new InvalidOperationException("The Windows graphics driver has not recovered yet.");
            journal?.Invoke("WindowsOwnsGpu");
            return new(true, "macOS is shut down.", state);
        }
        catch (Exception ex) { journal?.Invoke("Error: " + ex.Message); return new(false, ex.Message); }
        finally { Activity = ""; gate.Release(); }
    }
}

public static class BatteryPolicy
{
    public static bool ShouldShutdown(bool onBattery, int percent, bool guestRunning) =>
        onBattery && guestRunning && percent is >= 0 and <= 12;
}

public sealed record ClipboardSnapshot(long Revision, string? Text, string? Png, bool Supported = true);
public static class ClipboardPolicy
{
    public const int MaximumBytes = 16 * 1024 * 1024;
    public static bool Valid(ClipboardSnapshot s) => s.Supported &&
        (s.Text?.Length ?? 0) <= MaximumBytes / 2 && (s.Png?.Length ?? 0) <= MaximumBytes * 4 / 3 + 4;
    // A simultaneous host/guest edit is resolved toward the side the user is entering.
    public static string Direction(bool hostChanged, bool guestChanged, bool enteringGuest) =>
        hostChanged && (!guestChanged || enteringGuest) ? "toGuest" : guestChanged ? "toHost" : "none";
}
