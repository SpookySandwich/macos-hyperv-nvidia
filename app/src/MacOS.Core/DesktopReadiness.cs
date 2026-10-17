namespace MacOS.Core;

public sealed record GuestReadiness(bool BootReady, bool DesktopReady, bool NeedsSignIn, bool Locked, string ConsoleOwner,
    bool PasswordFieldReady = false, bool SessionSignedIn = false)
{
    public bool CanPresent => BootReady && DesktopReady && HasAuthenticatedSession;
    public bool CanSignIn => BootReady && NeedsSignIn && PasswordFieldReady && !DesktopReady && !SessionSignedIn &&
        (ConsoleOwner == "root" || (ConsoleOwner == MachineConfig.Current.GuestUser && Locked));
    public bool CanWakeSignIn => BootReady && NeedsSignIn && Locked && ConsoleOwner == MachineConfig.Current.GuestUser &&
        !PasswordFieldReady && !DesktopReady && !SessionSignedIn;
    public bool HasAuthenticatedSession => SessionSignedIn && !NeedsSignIn && !Locked && ConsoleOwner == MachineConfig.Current.GuestUser;
}

// One gate owns the readiness decision, including the sign-in race and retries.
// A responding SSH server or an initialized framebuffer alone is insufficient.
public sealed class DesktopReadinessGate
{
    public async Task<GuestReadiness> WaitAsync(
        Func<CancellationToken, Task<GuestReadiness?>> inspect,
        Func<CancellationToken, Task<bool>> signIn,
        CancellationToken ct,
        Func<CancellationToken, Task>? delay = null,
        TimeProvider? timeProvider = null,
        Func<CancellationToken, Task<bool>>? wake = null)
    {
        // State belongs to this launch attempt. A completed/rejected attempt
        // must not prevent a later reconnect or lock-screen sign-in.
        bool signInSubmitted = false, authenticationAccepted = false, wakeSubmitted = false;
        long? signInAt = null;
        timeProvider ??= TimeProvider.System;
        delay ??= token => Task.Delay(1000, token);
        while (true)
        {
            ct.ThrowIfCancellationRequested();
            var state = await inspect(ct);
            ct.ThrowIfCancellationRequested();
            if (state?.CanPresent == true) return state;
            if (state?.HasAuthenticatedSession == true) authenticationAccepted = true;
            if (!wakeSubmitted && !signInSubmitted && wake is not null && state?.CanWakeSignIn == true)
            {
                // A locked user's idle wallpaper is not a password field.
                // One non-secret wake key may reveal it; only a subsequent
                // verified secure-field observation permits the credential.
                var latest = await inspect(ct);
                ct.ThrowIfCancellationRequested();
                if (latest?.CanPresent == true) return latest;
                if (latest?.CanWakeSignIn == true) wakeSubmitted = await wake(ct);
                await delay(ct);
                continue;
            }
            if (!authenticationAccepted && state?.NeedsSignIn == true && signInAt is not null &&
                timeProvider.GetElapsedTime(signInAt.Value) > TimeSpan.FromSeconds(25))
                throw new IOException("macOS did not accept automatic sign-in. The VM is still running on its locked screen; Windows has not switched desktops.");
            if (!signInSubmitted && state?.CanSignIn == true)
            {
                // Read again just before sign-in. The user may have unlocked it.
                var latest = await inspect(ct);
                ct.ThrowIfCancellationRequested();
                if (latest?.CanPresent == true) return latest;
                if (latest?.CanSignIn == true)
                {
                    // A final check inside signIn may decline to submit if
                    // the session changed. Only actual input consumes the
                    // single attempt and starts the rejection timer.
                    signInSubmitted = await signIn(ct);
                    if (signInSubmitted)
                    {
                        authenticationAccepted = false;
                        signInAt = timeProvider.GetTimestamp();
                    }
                }
            }
            await delay(ct);
        }
    }
}
