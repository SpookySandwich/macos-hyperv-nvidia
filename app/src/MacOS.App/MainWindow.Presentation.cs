using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;

namespace MacOS.App;
public sealed partial class MainWindow
{
    void SetWindowedPresentation()
    {
        AppWindow.SetPresenter(AppWindowPresenterKind.Overlapped);
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(CaptionBar);
        CaptionBar.Visibility = Visibility.Visible;
        CaptionBar.AutoRefreshDragRegions = true;
        Root.RowDefinitions[0].Height = new GridLength(48);
    }
}
