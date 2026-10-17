using System.Diagnostics;
using System.Text;
using System.Text.Json;
using MacOS.Core;

namespace MacOS.App;
sealed class GuestConnection(ServiceClient service) : IDisposable
{
    Process? bridge;
    readonly SemaphoreSlim exchange = new(1);
    string? address;
    DisplayTarget? displayTarget;
    DisplayTarget? attemptedDisplayTarget;
    bool displayInstalled;
    bool audioInstalled;
    public async Task<Process> OpenAudioAsync(CancellationToken ct)
    {
        if(address is null)throw new IOException("Guest networking is unavailable.");
        const string directory="$HOME/Library/Application Support/macOS/Guest";
        if(!audioInstalled) {
            using var install=Process.Start(Ssh(address,$"set -e; mkdir -p \"{directory}\"; tar -xzf - -C \"{directory}\"; \"{directory}/AudioBridge.app/Contents/MacOS/AudioBridge\" --version")) ?? throw new IOException("Could not install audio integration.");
            var output=install.StandardOutput.ReadToEndAsync();var errors=install.StandardError.ReadToEndAsync();
            try {
                var archive=await File.ReadAllBytesAsync(Path.Combine(AppContext.BaseDirectory,"Guest","macos-audio.tar.gz"),ct);
                await install.StandardInput.BaseStream.WriteAsync(archive,ct);install.StandardInput.Close();
                await install.WaitForExitAsync(ct);
                if(install.ExitCode!=0 || (await output).Trim()!="2.0")throw new IOException("Audio integration installation failed: "+(await errors).Trim());
                audioInstalled=true;
            } finally { if(!install.HasExited)install.Kill(true); }
        }
        var process=Process.Start(Ssh(address,$"/usr/bin/python3 \"{directory}/audio-client.py\"")) ?? throw new IOException("Could not connect to macOS audio.");
        process.StandardInput.Close();return process;
    }
    public void ResetDisplayMatch() { displayTarget = null; attemptedDisplayTarget = null; }
    public async Task MatchDisplayAsync(DisplayTarget target, CancellationToken ct)
    {
        if (target == displayTarget || target == attemptedDisplayTarget) return;
        if (address is null) throw new IOException("Guest networking is unavailable.");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromSeconds(25));
        if (!displayInstalled) {
            var binary = await File.ReadAllBytesAsync(Path.Combine(AppContext.BaseDirectory,"Guest","macos-display"), deadline.Token);
            using var install = Process.Start(Ssh(address,"set -e; mkdir -p $HOME/.local/libexec; cat > $HOME/.local/libexec/macos-display.new; chmod 755 $HOME/.local/libexec/macos-display.new; mv $HOME/.local/libexec/macos-display.new $HOME/.local/libexec/macos-display")) ?? throw new IOException("Could not install display integration.");
            var errors=install.StandardError.ReadToEndAsync(); var output=install.StandardOutput.ReadToEndAsync();
            try {
                await install.StandardInput.BaseStream.WriteAsync(binary,deadline.Token);install.StandardInput.Close();
                await install.WaitForExitAsync(deadline.Token);
                if(install.ExitCode!=0)throw new IOException("Display integration installation failed: "+(await errors).Trim());
                _=await output;displayInstalled=true;
            } finally {if(!install.HasExited)install.Kill(true);}
        }
        // An SSH disconnect does not necessarily kill a blocked remote display
        // query. Its guest-side watchdog must own and reap the child as well.
        string modeCommand = $"/usr/bin/python3 -c 'import os,subprocess,sys; p=subprocess.run([os.path.expanduser(\"~/.local/libexec/macos-display\"),\"{target.Width}\",\"{target.Height}\",\"{target.RefreshHz}\"],timeout=20); sys.exit(p.returncode)'";
        using var process=Process.Start(Ssh(address,modeCommand)) ?? throw new IOException("Could not match the display.");
        process.StandardInput.Close();var reply=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();
        try {
            await process.WaitForExitAsync(deadline.Token);
            if(process.ExitCode!=0) {
                // Unsupported geometry must not spawn an SSH process on every
                // monitor tick. Retry on a new monitor or console connection.
                if(process.ExitCode==3)attemptedDisplayTarget=target;
                throw new IOException("Display matching failed: "+(await error).Trim());
            }
            using var document=JsonDocument.Parse(await reply);
            var current=document.RootElement.GetProperty("current");
            if(current.GetProperty("width").GetInt32()!=target.Width || current.GetProperty("height").GetInt32()!=target.Height ||
               Math.Abs(current.GetProperty("refreshHz").GetDouble()-target.RefreshHz)>0.5)
                throw new IOException("macOS did not confirm the requested resolution and refresh rate.");
            displayTarget=target;
        } finally {if(!process.HasExited)process.Kill(true);}
    }
    readonly DesktopReadinessGate readiness = new();
    public GuestReadiness? LastReady { get; private set; }
    static ProcessStartInfo Ssh(string address, string command)
    {
        if (!System.Net.IPAddress.TryParse(address, out _)) throw new IOException("Guest networking is unavailable.");
        var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe"))
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardInputEncoding = new UTF8Encoding(false), StandardOutputEncoding = Encoding.UTF8 };
        foreach (var arg in new[] { "-i", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".ssh", "id_macos_hyperv"), "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=10", "-o", "ServerAliveCountMax=2", "-T", MachineConfig.Current.GuestUser + "@" + address, command }) start.ArgumentList.Add(arg);
        return start;
    }
    public async Task WaitReadyAsync(CancellationToken ct)
    {
        LastReady = null;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(TimeSpan.FromMinutes(3));
        try { LastReady = await readiness.WaitAsync(InspectReadinessAsync, SignInAsync, deadline.Token, wake: WakeSignInAsync); }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new IOException("macOS has not reached its unlocked desktop. Your Windows desktop remains active. macOS is still running; try again after completing sign-in.");
        }
    }
    public async Task<GuestReadiness?> InspectReadinessAsync(CancellationToken ct)
    {
        address ??= (await service.SendAsync("status", ct)).Machine?.Address;
        if (address is null) return null;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(12));
        using var process = Process.Start(Ssh(address, "/usr/bin/caffeinate -u -t 1; /usr/bin/python3 -")) ?? throw new IOException("Could not check the macOS desktop.");
        var errors = process.StandardError.ReadToEndAsync();
        var output = process.StandardOutput.ReadToEndAsync();
        try
        {
            var script = await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "Guest", "readiness.py"), deadline.Token);
            await process.StandardInput.WriteAsync(script.AsMemory(), deadline.Token);
            process.StandardInput.Close();
            await process.WaitForExitAsync(deadline.Token);
            if (process.ExitCode != 0) { address = null; return null; }
            return JsonSerializer.Deserialize<GuestReadiness>(await output, Protocol.Json);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { address = null; return null; }
        catch (IOException) { address = null; return null; } // SSH may reset while the guest boots.
        catch (JsonException) { return null; }
        finally { if (!process.HasExited) process.Kill(true); _ = await errors; _ = await output; }
    }
    async Task<bool> WakeSignInAsync(CancellationToken ct)
    {
        if ((await InspectReadinessAsync(ct))?.CanWakeSignIn != true) return false;
        ct.ThrowIfCancellationRequested();
        var reply = await service.SendAsync("wake", ct);
        if (!reply.Success) throw new IOException(reply.Message);
        return true;
    }
    async Task<bool> SignInAsync(CancellationToken ct)
    {
        string? secret = StoredCredential.Read();
        try
        {
            // Credential retrieval and networking can take time; do not type
            // into an application if the user has meanwhile signed in.
            if ((await InspectReadinessAsync(ct))?.CanSignIn != true) return false;
            ct.ThrowIfCancellationRequested();
            var reply = await service.SendAsync("unlock", ct, secret);
            if (!reply.Success) throw new IOException(reply.Message);
            return true;
        }
        finally { secret = null; }
    }
    public async Task EnsureBridgeAsync(CancellationToken ct)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct); deadline.CancelAfter(TimeSpan.FromSeconds(15));
        using var check = Process.Start(Ssh(address!, "test -x $HOME/.local/libexec/macos-bridge && $HOME/.local/libexec/macos-bridge --version")) ?? throw new IOException("Could not check clipboard integration.");
        check.StandardInput.Close();
        var result = check.StandardOutput.ReadToEndAsync(deadline.Token); var error = check.StandardError.ReadToEndAsync(deadline.Token);
        try { await check.WaitForExitAsync(deadline.Token); }
        catch { if (!check.HasExited) check.Kill(true); throw; }
        if (check.ExitCode == 0 && (await result).Trim() == "1.0") return;
        _ = await error;
        var binary = await File.ReadAllBytesAsync(Path.Combine(AppContext.BaseDirectory, "Guest", "macos-bridge"), ct);
        using var install = Process.Start(Ssh(address!, "set -e; mkdir -p $HOME/.local/libexec; cat > $HOME/.local/libexec/macos-bridge.new; chmod 755 $HOME/.local/libexec/macos-bridge.new; mv $HOME/.local/libexec/macos-bridge.new $HOME/.local/libexec/macos-bridge")) ?? throw new IOException("Could not install clipboard integration.");
        var errors = install.StandardError.ReadToEndAsync(deadline.Token); var output = install.StandardOutput.ReadToEndAsync(deadline.Token);
        try { await install.StandardInput.BaseStream.WriteAsync(binary, deadline.Token); install.StandardInput.Close(); await install.WaitForExitAsync(deadline.Token); }
        catch { if (!install.HasExited) install.Kill(true); throw; }
        if (install.ExitCode != 0) throw new IOException("Clipboard integration installation failed: " + (await errors).Trim());
        _ = await output;
    }
    public async Task<ClipboardSnapshot> ClipboardAsync(object request, CancellationToken ct)
    {
        await exchange.WaitAsync(ct);
        try
        {
            if (address is null) throw new IOException("Guest networking is unavailable.");
            if (bridge is null || bridge.HasExited)
            {
                bridge?.Dispose();
                bridge = Process.Start(Ssh(address, "$HOME/.local/libexec/macos-bridge")) ?? throw new IOException("Could not connect to the macOS clipboard.");
                _ = bridge.StandardError.ReadToEndAsync();
            }
            await bridge.StandardInput.WriteLineAsync(JsonSerializer.Serialize(request).AsMemory(), ct);
            await bridge.StandardInput.FlushAsync(ct);
            var line = await bridge.StandardOutput.ReadLineAsync(ct) ?? throw new IOException("The macOS clipboard disconnected.");
            if (line.Length > ClipboardPolicy.MaximumBytes * 2) throw new IOException("Clipboard data is too large.");
            return JsonSerializer.Deserialize<ClipboardSnapshot>(line, Protocol.Json) ?? throw new IOException("Invalid clipboard reply.");
        }
        catch { StopBridge(); throw; }
        finally { exchange.Release(); }
    }
    void StopBridge() { if (bridge is not null) { try { if (!bridge.HasExited) bridge.Kill(true); } catch { } bridge.Dispose(); bridge = null; } }
    public void Dispose() => StopBridge();
}
