namespace MacOS.Core;
public sealed record DisplayTarget(int Width, int Height, int RefreshHz)
{
    public static DisplayTarget Create(int width, int height, int refreshHz)
    {
        if (width < 640 || height < 480 || width > 16384 || height > 16384)
            throw new ArgumentOutOfRangeException(nameof(width), "Invalid display dimensions.");
        return new(width, height, refreshHz is >=24 and <=240 ? refreshHz : 60);
    }
}
