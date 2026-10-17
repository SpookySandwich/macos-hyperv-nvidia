namespace MacOS.Core;
public static class ViewerGeometry
{
    // Basic Hyper-V video uses the ActiveX zoom path. Keep the entire desktop
    // inside the viewport, preserve aspect ratio, and avoid unnecessary upscaling.
    public static uint FitPercent(int viewWidth, int viewHeight, int guestWidth, int guestHeight)
    {
        if (viewWidth <= 0 || viewHeight <= 0 || guestWidth <= 0 || guestHeight <= 0) return 0;
        return (uint)Math.Clamp(Math.Min((long)viewWidth * 100 / guestWidth, (long)viewHeight * 100 / guestHeight), 10, 100);
    }
}
