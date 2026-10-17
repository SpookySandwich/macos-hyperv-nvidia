import json
import os
import plistlib
import subprocess
from xml.parsers.expat import ExpatError
import getpass

# The readiness probe runs over SSH as the guest account that signs in to the desktop.
GUEST_USER = getpass.getuser()


def registry(*args):
    # Missing services are normal during boot: ioreg exits successfully with
    # no plist. Transient command/parse failures must also fail closed.
    try:
        raw = subprocess.check_output(
            ['/usr/sbin/ioreg', '-a', *args], timeout=5,
            stderr=subprocess.DEVNULL)
        if not raw.strip():
            return []
        obj = plistlib.loads(raw)
        rows = obj if isinstance(obj, list) else [obj]
        return [row for row in rows if isinstance(row, dict)]
    except (OSError, ValueError, ExpatError, plistlib.InvalidFileException,
            subprocess.SubprocessError):
        return []


def console_owner():
    try:
        import pwd
        return pwd.getpwuid(os.stat('/dev/console').st_uid).pw_name
    except (OSError, KeyError):
        return ''


def console_sessions(root):
    sessions = root.get('IOConsoleUsers', [])
    if not isinstance(sessions, list):
        return []
    return [s for s in sessions if isinstance(s, dict) and
            s.get('kCGSSessionOnConsoleKey') is True]


def prelogin_security_agent_ready():
    # A fresh login session can retain the bootstrap secure-input PID after
    # that process exits. Require both native prelogin processes under their
    # system accounts; this fallback is never used for an authenticated user.
    try:
        import pwd
        agent_uid = pwd.getpwnam('_securityagent').pw_uid
        raw = subprocess.check_output(
            ['/bin/ps', '-axo', 'uid=', '-o', 'comm='], timeout=2,
            stderr=subprocess.DEVNULL).decode('utf-8')
        expected = {
            (0, '/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow'),
            (agent_uid, '/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent')}
        found = set()
        for line in raw.splitlines():
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0].isdigit():
                found.add((int(parts[0]), parts[1]))
        return expected.issubset(found)
    except (OSError, KeyError, ImportError, UnicodeError, subprocess.SubprocessError):
        return False


def password_field_ready(sessions, owner='', locked=False):
    # A booted GPU and /dev/console owned by root do not establish that the
    # password field is ready. macOS reports the process that currently owns
    # secure keyboard input. Only loginwindow is an automatic sign-in target;
    # an application's password prompt must never receive this credential.
    expected = '/System/Library/CoreServices/loginwindow.app/Contents/MacOS/loginwindow'
    for session in sessions:
        pid = session.get('kCGSSessionSecureInputPID')
        if type(pid) is not int or pid <= 0:
            continue
        try:
            command = subprocess.check_output(
                ['/bin/ps', '-p', str(pid), '-o', 'comm='], timeout=2,
                stderr=subprocess.DEVNULL).decode('utf-8').strip()
            if command == expected:
                return True
            # A live unrelated process owning secure input is never a target.
            continue
        except subprocess.CalledProcessError as error:
            # Observed on the actual fresh-boot password screen: the secure
            # input PID has exited, while the locked unauthenticated console
            # belongs to WindowServer and SecurityAgent owns the login UI.
            # ps exits 1 with no process rows when the PID has exited. A
            # timeout, command failure, or undecodable live owner is not that
            # evidence and must never enable the fallback.
            if (error.returncode == 1 and not (error.output or b'').strip() and
                    owner == 'root' and locked and
                    not any(s.get('kCGSessionLoginDoneKey') is True for s in sessions) and
                    session.get('kCGSessionLoginDoneKey') is False and
                    session.get('kCGSSessionUserNameKey') == 'unknown' and
                    type(session.get('kCGSSessionUserIDKey')) is int and
                    session.get('kCGSSessionUserIDKey') == 88 and
                    prelogin_security_agent_ready()):
                return True
        except (OSError, UnicodeError, subprocess.SubprocessError):
            continue
    return False


def assess(root, owner, framebuffers, rms, accels, dock, password_ready):
    sessions = console_sessions(root)
    locked = root.get('IOConsoleLocked') is True or any(
        s.get('CGSSessionScreenIsLocked') is True for s in sessions)
    signed_in = any(s.get('kCGSSessionUserNameKey') == GUEST_USER and
                    s.get('kCGSessionLoginDoneKey') is True for s in sessions)
    framebuffer = any(r.get('HyperVConsoleScanoutReady') is True and
                      r.get('HyperVConsoleRegistrationStatus') == 0
                      for r in framebuffers)
    rm = any(r.get('nvrm-autogo') == 'up' for r in rms)
    boot = framebuffer and rm and bool(accels)
    needs_sign_in = bool(root) and (owner == 'root' or locked)
    return {'BootReady': boot,
            'DesktopReady': boot and owner == GUEST_USER and signed_in and not locked and dock,
            'NeedsSignIn': needs_sign_in,
            'Locked': locked, 'ConsoleOwner': owner,
            'PasswordFieldReady': needs_sign_in and password_ready,
            'SessionSignedIn': owner == GUEST_USER and signed_in and not locked}


def inspect():
    roots = registry('-n', 'Root', '-d1')
    root = roots[0] if roots else {}
    owner = console_owner()
    framebuffers = registry('-r', '-c', 'HyperVGraphicsFramebuffer')
    rms = registry('-r', '-c', 'NVRM')
    accels = registry('-r', '-c', 'NVAccel')
    try:
        dock = subprocess.run(['/usr/bin/pgrep', '-u', GUEST_USER, '-x', 'Dock'],
                              stdout=subprocess.DEVNULL,
                              stderr=subprocess.DEVNULL, timeout=2).returncode == 0
    except (OSError, subprocess.SubprocessError):
        dock = False
    password_ready = False
    if owner == 'root' or root.get('IOConsoleLocked') is True or any(
            s.get('CGSSessionScreenIsLocked') is True for s in console_sessions(root)):
        password_ready = password_field_ready(console_sessions(root), owner,
                                               root.get('IOConsoleLocked') is True)
    return assess(root, owner, framebuffers, rms, accels, dock, password_ready)


if __name__ == '__main__':
    print(json.dumps(inspect()))
