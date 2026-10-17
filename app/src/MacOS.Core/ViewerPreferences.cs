using System.Text.Json;

namespace MacOS.Core;
public static class ViewerPreferences
{
    public static DisplayTarget Default { get; } = new(1280, 720, 60);
    public static DisplayTarget FullHD { get; } = new(1920, 1080, 60);
    static bool Supported(DisplayTarget? value) => value == Default || value == FullHD;
    public static DisplayTarget Load(string path)
    {
        try
        {
            var value = JsonSerializer.Deserialize<DisplayTarget>(File.ReadAllText(path));
            return Supported(value) ? value! : Default;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { return Default; }
    }
    public static void Save(string path, DisplayTarget value)
    {
        if (!Supported(value)) throw new ArgumentOutOfRangeException(nameof(value));
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var pending = path + ".new";
        File.WriteAllText(pending, JsonSerializer.Serialize(value));
        File.Move(pending, path, true);
    }
}
