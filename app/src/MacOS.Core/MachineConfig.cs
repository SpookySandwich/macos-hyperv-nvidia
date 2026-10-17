using System.Text.Json;

namespace MacOS.Core;

// Machine-specific identities, read from machine.json next to the executable.
// The build copies app/src/machine.json (created from machine.example.json)
// into both the app and the service output; host.ps1 reads the same file.
public sealed record MachineConfig(string VmName, string VmId, string GuestUser)
{
    static readonly Lazy<MachineConfig> current = new(Load);
    public static MachineConfig Current => current.Value;

    static MachineConfig Load()
    {
        string path = Path.Combine(AppContext.BaseDirectory, "machine.json");
        if (!File.Exists(path)) throw new FileNotFoundException("machine.json is missing. Copy machine.example.json to machine.json before building.", path);
        var config = JsonSerializer.Deserialize<MachineConfig>(File.ReadAllText(path), Protocol.Json)
            ?? throw new InvalidDataException("machine.json is invalid.");
        if (!Guid.TryParse(config.VmId, out _) || string.IsNullOrWhiteSpace(config.VmName) ||
            string.IsNullOrWhiteSpace(config.GuestUser) || config.GuestUser.StartsWith('<'))
            throw new InvalidDataException("machine.json still has placeholder values.");
        return config;
    }
}
