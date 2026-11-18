using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Tutun.Core;
using static Tutun.App.UI;

namespace Tutun.App;

internal sealed class TrayPanel : Window
{
    readonly AppModel model = AppModel.Shared;
    readonly ServerList servers;
    readonly TextBlock status = T("", 14, FontWeights.SemiBold);
    readonly TextBlock country = T("", 26, FontWeights.Heavy);
    readonly Button toggle;

    public TrayPanel(MainWindow owner, Action showMain, Action quit)
    {
        Title = "Tutun";
        Width = 340;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Background = B("Bg");
        servers = new ServerList(owner, compact: true);
        servers.View.Height = 250;
        toggle = Btn("", async () =>
        {
            if (!model.DaemonReachable || model.DaemonOutdated) { showMain(); return; }
            await model.Toggle();
        }, primary: true);
        var open = Btn("Открыть окно", showMain);
        var settings = IconButton("gearshape", () => { showMain(); owner.SetPanel(SidePanel.Settings); }, "Настройки");
        var exit = IconButton("xmark", quit, "Закрыть Tutun. VPN продолжит работать через службу");
        Content = new Border { Padding = new Thickness(16), BorderBrush = B("Line"), BorderThickness = new Thickness(1),
            Child = V(8, status, country, toggle, Header("Серверы"), servers.View, Row(open, settings, exit)) };
        SourceInitialized += (_, _) =>
        {
            var cursor = System.Windows.Forms.Cursor.Position;
            var work = System.Windows.Forms.Screen.FromPoint(cursor).WorkingArea;
            var source = HwndSource.FromHwnd(new WindowInteropHelper(this).Handle);
            var transform = source.CompositionTarget.TransformFromDevice;
            var anchor = transform.Transform(new Point(cursor.X, cursor.Y));
            var bounds = Rect.Transform(new Rect(work.Left, work.Top, work.Width, work.Height), transform);
            Left = Math.Clamp(anchor.X - Width / 2, bounds.Left, Math.Max(bounds.Left, bounds.Right - Width));
            MaxHeight = bounds.Height;
            Loaded += (_, _) => Top = Math.Clamp(anchor.Y - ActualHeight, bounds.Top, Math.Max(bounds.Top, bounds.Bottom - ActualHeight));
        };
        Deactivated += (_, _) => Close();
        KeyDown += (_, e) => { if (e.Key == Key.Escape) Close(); };
        model.Changed += Refresh;
        Closed += (_, _) => model.Changed -= Refresh;
        Refresh();
    }

    void Refresh()
    {
        status.Text = L.T(StatusText.Title(model.Status, model.DaemonReachable));
        status.Foreground = B(StatusText.Color(model.Status, model.DaemonReachable));
        country.Text = model.CurrentCountryName ?? model.SelectionTitle;
        toggle.Content = L.T(!model.DaemonReachable || model.DaemonOutdated ? "Открыть Tutun" : model.IsConnected ? "Отключить" : "Подключить");
        toggle.IsEnabled = !model.Busy;
        servers.Rebuild();
    }
}
