using System.IO.Pipes;
using System.Text;
using System.Text.Json;

namespace MacOS.Core;
public sealed class ServiceClient
{
    public async Task<SessionReply> SendAsync(string action, CancellationToken ct = default, string? secret = null)
    {
        if (!Protocol.Allowed(action)) throw new ArgumentException("Unknown operation.", nameof(action));
        using var pipe = new NamedPipeClientStream(".", Protocol.Pipe, PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(5000, ct);
        using var writer = new StreamWriter(pipe, new UTF8Encoding(false), leaveOpen: true) { AutoFlush = true };
        using var reader = new StreamReader(pipe, Encoding.UTF8, leaveOpen: true);
        await writer.WriteLineAsync(JsonSerializer.Serialize(new Request(action, secret)).AsMemory(), ct);
        var line = await reader.ReadLineAsync(ct) ?? throw new IOException("The macOS service disconnected.");
        return JsonSerializer.Deserialize<SessionReply>(line, Protocol.Json) ?? throw new IOException("Invalid service reply.");
    }
}
