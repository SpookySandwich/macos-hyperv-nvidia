"""Forward only the GUI helper's BlackHole output, using the existing SSH channel."""
import pathlib,socket,subprocess,sys,time
root=pathlib.Path(__file__).resolve().parent
subprocess.run(['open','-g','-a',str(root/'AudioBridge.app')],check=True)
path=pathlib.Path.home()/'Library/Caches/MacHyperVAudio.sock'
with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
    for attempt in range(100):
        try:
            client.connect(str(path));break
        except (FileNotFoundError,ConnectionRefusedError):
            if attempt==99:
                print('Allow macOS audio forwarding in Privacy & Security > Microphone. Only the BlackHole virtual device is captured.',file=sys.stderr)
                sys.exit(3)
            time.sleep(.2)
    client.settimeout(10)
    try:
        while True:
            data=client.recv(8192)
            if not data:break
            sys.stdout.buffer.write(data);sys.stdout.buffer.flush()
    except BrokenPipeError:
        pass
