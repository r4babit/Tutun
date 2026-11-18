using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using Tutun.Core;
using static Tutun.App.UI;

namespace Tutun.App;

/// Главное окно: одна страница. Слева — состояние и кнопка, справа выезжает панель (серверы, настройки, добавить).
public sealed class MainWindow : Window
{
    public const double LeftWidth = 460, PanelWidth = 460, WindowHeight = 736;
    readonly AppModel m = AppModel.Shared;
    readonly ContentControl left = new();
    readonly Border panelHost = new() { BorderBrush = B("Line"), BorderThickness = new Thickness(1, 0, 0, 0) };
    readonly ServerList serverList;
    readonly SettingsPanel settingsPanel;
    readonly AddPanel addPanel;
    readonly Border toast = new() { Visibility = Visibility.Collapsed };
    readonly System.Windows.Threading.DispatcherTimer toastTimer = new() { Interval = TimeSpan.FromSeconds(4) };

    public MainWindow()
    {
        Title = "Tutun";
        Background = B("Bg");
        ResizeMode = ResizeMode.CanMinimize;
        Height = WindowHeight;
        Width = LeftWidth + 16;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        AllowDrop = true;
        Icon = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/tutun.ico"));
        UseLayoutRounding = true;

        serverList = new ServerList(this);
        settingsPanel = new SettingsPanel(this);
        addPanel = new AddPanel(this);

        var grid = new Grid { ClipToBounds = true };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(LeftWidth) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(PanelWidth) });
        grid.Children.Add(left);
        Grid.SetColumn(panelHost, 1);
        grid.Children.Add(panelHost);

        // Плашка-сообщение поверх содержимого.
        toast.HorizontalAlignment = HorizontalAlignment.Center;
        toast.VerticalAlignment = VerticalAlignment.Bottom;
        toast.Margin = new Thickness(14, 0, 14, 16);
        toast.MaxWidth = 400;
        Grid.SetColumnSpan(toast, 2);
        grid.Children.Add(toast);
        Content = grid;

        toastTimer.Tick += (_, _) => { toastTimer.Stop(); m.Message = null; };
        m.Changed += Refresh;
        m.MessageChanged += ShowMessage;
        UpdateModel.Shared.Changed += Refresh;
        L.Changed += () => { bottomSignature = ""; SetPanel(m.Panel); Refresh(); };
        SourceInitialized += (_, _) => SystemIntegration.DarkTitleBar(new WindowInteropHelper(this).Handle);
        Closing += (_, e) => { e.Cancel = true; if (m.Panel == SidePanel.Settings && m.NeedsApply) m.DiscardDraft(); Hide(); };   // окно прячется в трей, VPN держит служба
        Drop += OnDrop;
        Refresh();
        SetPanel(m.Panel);
    }

    // MARK: панель справа

    public void TogglePanel(SidePanel p) => SetPanel(m.Panel == p ? null : p);

    public void SetPanel(SidePanel? p)
    {
        // Как на маке: закрытие настроек отбрасывает непринятый черновик.
        if (m.Panel == SidePanel.Settings && p != SidePanel.Settings && m.NeedsApply)
        {
            m.DiscardDraft();
            m.Message = "Непринятые изменения настроек отменены";
        }
        var old = m.Panel;
        m.Panel = p;
        // Анимации как на маке; при выключенной «Показывать анимацию в Windows» — без них.
        var animate = IsLoaded && Animations;
        if (p != null)
        {
            var view = p switch { SidePanel.Servers => serverList.View, SidePanel.Settings => settingsPanel.View, _ => addPanel.View };
            panelHost.Child = view;
            if (p == SidePanel.Settings) settingsPanel.Rebuild();
            if (p == SidePanel.Add) addPanel.Rebuild(prefill: old != SidePanel.Add);
            if (p == SidePanel.Servers) serverList.Rebuild(force: true);
            // Переключение между панелями: окно того же размера, содержимое плавно проявляется (0,18 с).
            if (old != null && old != p && animate) Fade(view, 0, 1, 0.18);
            else { view.BeginAnimation(OpacityProperty, null); view.Opacity = 1; }
        }
        Grid.SetColumnSpan(toast, p == null ? 1 : 2);
        ResizeForPanel(p != null, animate);
        RefreshLeft();
    }

    EventHandler? panelFrame;
    double panelTargetWidth = LeftWidth + 16;

    void ResizeForPanel(bool open, bool animate)
    {
        var target = LeftWidth + 16 + (open ? PanelWidth : 0);
        if (animate && panelTargetWidth == target) return;
        panelTargetWidth = target;

        // The client area clips the full-width panel as the actual right window edge moves.
        // Start at the displayed width so a second click can reverse a transition mid-flight.
        if (panelFrame != null) CompositionTarget.Rendering -= panelFrame;
        panelFrame = null;
        var from = ActualWidth > 0 ? ActualWidth : Width;
        if (!animate || Math.Abs(target - from) < 1)
        {
            Width = target;
            if (!open) panelHost.Child = null;
            return;
        }

        var elapsed = System.Diagnostics.Stopwatch.StartNew();
        panelFrame = (_, _) =>
        {
            var t = Math.Min(1, elapsed.Elapsed.TotalMilliseconds / 320);
            Width = from + (target - from) * (0.5 - 0.5 * Math.Cos(Math.PI * t));
            if (t < 1) return;
            CompositionTarget.Rendering -= panelFrame;
            panelFrame = null;
            if (!open) panelHost.Child = null;
        };
        CompositionTarget.Rendering += panelFrame;
    }

    public static void Fade(UIElement e, double from, double to, double seconds, Action? done = null)
    {
        var a = new System.Windows.Media.Animation.DoubleAnimation(from, to, TimeSpan.FromSeconds(seconds))
        {
            EasingFunction = new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseInOut },
        };
        if (done != null) a.Completed += (_, _) => done();
        e.BeginAnimation(OpacityProperty, a);
    }

    void Refresh()
    {
        RefreshLeft();
        if (m.Panel == SidePanel.Servers) serverList.Rebuild();
        if (m.Panel == SidePanel.Settings) settingsPanel.RefreshApplyBar();
        if (m.Panel == SidePanel.Add) addPanel.RefreshList();
    }

    void ShowMessage()
    {
        if (m.Message is not { } text)
        {
            // Исчезновение прозрачностью 0,15 с.
            if (toast.Visibility == Visibility.Visible && Animations)
                Fade(toast, toast.Opacity, 0, 0.15, () => { if (m.Message == null) toast.Visibility = Visibility.Collapsed; });
            else toast.Visibility = Visibility.Collapsed;
            return;
        }
        var close = IconButton("xmark", () => m.Message = null, "Закрыть", 11);
        toast.Child = Card(Row(T(L.T(text), 13, FontWeights.Medium, wrap: true), close), 11, new Thickness(14, 10, 8, 10));
        toast.Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 16, ShadowDepth = 3, Opacity = 0.35 };
        var wasVisible = toast.Visibility == Visibility.Visible && toast.Opacity > 0.9;
        toast.Visibility = Visibility.Visible;
        if (!wasVisible && Animations) Fade(toast, 0, 1, 0.15); else { toast.BeginAnimation(OpacityProperty, null); toast.Opacity = 1; }
        toastTimer.Stop(); toastTimer.Start();
    }

    // MARK: левая колонка

    readonly ContentControl leftTop = new(), leftBottom = new();
    Border? leftRoot;
    string bottomSignature = "";

    void RefreshLeft()
    {
        var stateColor = StatusText.Color(m.Status, m.DaemonReachable);
        if (leftRoot == null)
        {
            var root = new Grid { Margin = new Thickness(32, 32, 32, 32) };
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            root.Children.Add(leftTop);
            Grid.SetRow(leftBottom, 2);
            root.Children.Add(leftBottom);
            leftRoot = new Border { Child = root };
            left.Content = leftRoot;
        }

        var top = new StackPanel();
        if (m.Status.EmergencyBlock && m.Status.State != TunnelState.Running)
        {
            top.Children.Add(Banner("Защита активна. Внешний трафик заблокирован."));

        }
        // Предупреждения
        if (m.ConflictList.Count > 0) top.Children.Add(WithMargin(Banner(L.F("Работает другой VPN: %@. Выключите его.", string.Join(", ", m.ConflictList))), 0, 0, 0, 14));
        if (UpdateModel.Shared.Available is { } upd)
        {
            var banner = Banner(L.F("Доступна версия %@", upd.Version) + ". " + L.T(Updater.VpnStaysNote) + " " + L.T("Установить — «Настройки → О Tutun»."), "On");
            banner.Cursor = Cursors.Hand;
            banner.MouseLeftButtonUp += (_, _) => { SetPanel(SidePanel.Settings); settingsPanel.ShowAbout(); };
            top.Children.Add(WithMargin(banner, 0, 0, 0, 14));
        }
        if (m.DaemonOutdated) top.Children.Add(WithMargin(Banner("Служба от другой версии Tutun — нажмите «Обновить службу»."), 0, 0, 0, 14));

        var dot = new Ellipse { Width = 8, Height = 8, Fill = B(stateColor) };
        top.Children.Add(H(6, dot, T(StatusText.Title(m.Status, m.DaemonReachable), 14, FontWeights.SemiBold, stateColor)));
        var big = T(m.CurrentCountryName ?? m.SelectionTitle, 39, FontWeights.Heavy);
        big.Margin = new Thickness(0, 4, 0, 4);
        top.Children.Add(big);
        top.Children.Add(T(Subtitle(), 14, color: "Text2"));

        // Карточка сервера
        var s = m.CurrentServer;
        UIElement badge = s?.CountryCode is { } cc ? CountryBadge(cc, 26)
            : m.CurrentCountryCode is { } c2 ? CountryBadge(c2, 26)
            : m.Applied.AutoSelect ? GlyphBadge("bolt.fill", 26) : GlyphBadge("network", 26, "Text2");
        var cardText = V(2, T(s != null ? m.CleanName(s) : m.SelectionTitle, 15, FontWeights.SemiBold), T(CardSubtitle(s), 12, color: "Text2"));
        var card = Card(Row(H(12, badge, cardText), s != null ? SignalBars(m.Pings.TryGetValue(s.Id, out var p) ? p : null) : new Border()));
        card.Padding = new Thickness(14);
        card.Margin = new Thickness(0, 21, 0, 0);
        top.Children.Add(card);

        if (m.IsConnected && (!m.Status.EmergencyBlock || m.Status.State == TunnelState.Running))
        {
            var tiles = StatsRow(
                StatTile("Задержка", m.CurrentLatency is { } l ? L.F("%@ мс", l) : "—"),
                StatTile("Загрузка", Format.Speed(m.SpeedDown)),
                m.Status.Since is { } since ? StatTile("В сети", Elapsed(since)) : StatTile("Отдача", Format.Speed(m.SpeedUp)));
            tiles.Margin = new Thickness(0, 21, 0, 0);
            top.Children.Add(tiles);
            var spark = Sparkline(m.History);
            spark.Margin = new Thickness(0, 21, 0, 0);
            top.Children.Add(spark);
        }
        leftTop.Content = top;

        // Кнопки перестраиваются только при смене их состояния — иначе ежесекундное обновление съедало бы клики.
        var sig = $"{m.Panel}|{m.Busy}|{m.IsConnected}|{m.DaemonReachable}|{m.DaemonOutdated}|{m.Status.State}|{m.Status.EmergencyBlock}|{m.Status.Mode}|{m.ServiceStage}";
        if (sig != bottomSignature)
        {
            bottomSignature = sig;
            var bottom = new StackPanel();
            bottom.Children.Add(ActionTiles());
            var main = MainButton();
            main.Margin = new Thickness(0, 21, 0, 0);
            bottom.Children.Add(main);
            leftBottom.Content = bottom;
        }

        // Мягкое свечение цвета состояния сверху.
        var glow = new RadialGradientBrush(((SolidColorBrush)B(stateColor)).Color, Colors.Transparent)
        {
            Center = new Point(0.5, 0.15), GradientOrigin = new Point(0.5, 0.15), RadiusX = 0.8, RadiusY = 0.5,
        };
        glow.GradientStops[0].Color = Color.FromArgb((byte)(m.IsConnected && m.Status.State == TunnelState.Running ? 40 : 14), glow.GradientStops[0].Color.R, glow.GradientStops[0].Color.G, glow.GradientStops[0].Color.B);
        leftRoot.Background = glow;
    }

    static T2 WithMargin<T2>(T2 e, double l, double t, double r, double b) where T2 : FrameworkElement { e.Margin = new Thickness(l, t, r, b); return e; }

    static string Elapsed(DateTimeOffset since)
    {
        var d = DateTimeOffset.Now - since;
        return d.TotalHours >= 1 ? $"{(int)d.TotalHours}:{d.Minutes:00}:{d.Seconds:00}" : $"{d.Minutes}:{d.Seconds:00}";
    }

    string Subtitle()
    {
        if (!m.DaemonReachable) return m.ServiceInstalled ? "Служба Tutun не отвечает" : "Установите службу, чтобы подключаться";
        if (m.IsConnected)
        {
            var parts = new List<string>();
            if (m.IpVPN is { } ip) parts.Add("IP " + ip.Ip);
            if (m.Applied.RoutingMode == RoutingMode.Global) parts.Add("всё через VPN");
            if (m.Applied.RoutingMode == RoutingMode.Direct) parts.Add("напрямую");
            if (m.Applied.Mode == ConnectionMode.Proxy) parts.Add("системный прокси");
            return string.Join(" · ", parts);
        }
        return "Нажмите «Подключить»";
    }

    string CardSubtitle(Server? s)
    {
        var byCountry = m.Applied.CountryPick switch
        {
            CountryPick.LastUsed => "последний выбранный",
            CountryPick.First => "первый в списке",
            CountryPick.Random => "случайный из списка",
            _ => "самый быстрый из списка",
        };
        var how = m.Settings.AutoSelect ? "выбран автоматически" : (m.Settings.SelectedCountry != null ? byCountry : "выбран вручную");
        if (s == null) return m.IsConnected ? how : (m.Settings.AutoSelect ? "Tutun выберет сам" : how);
        return $"{s.Proto} · {s.Transport} · {L.T(how)}";
    }

    static Grid StatsRow(params UIElement[] items)
    {
        var row = new Grid();
        foreach (var item in items)
        {
            if (row.Children.Count > 0) row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(9) });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            Grid.SetColumn(item, row.ColumnDefinitions.Count - 1);
            row.Children.Add(item);
        }
        return row;
    }

    static Border StatTile(string label, string value) => new()
    {
        Background = B("Card"), CornerRadius = new CornerRadius(10), Padding = new Thickness(11.5), MinHeight = 58,
        Child = V(2, T(label, 12, color: "Text2"), T(value, 16, FontWeights.SemiBold)),
    };

    static FrameworkElement Sparkline(List<double> values)
    {
        const double height = 39, width = LeftWidth - 64;
        var peak = Math.Max(values.DefaultIfEmpty(0).Max(), 1);
        var green = ((SolidColorBrush)B("On")).Color;
        var blue = ((SolidColorBrush)B("Brand")).Color;
        var line = new Polyline { Stroke = new LinearGradientBrush(green, blue, 0), StrokeThickness = 1.8,
            StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round, StrokeLineJoin = PenLineJoin.Round };
        var area = new Polygon { Fill = new LinearGradientBrush(Color.FromArgb(71, green.R, green.G, green.B),
            Color.FromArgb(0, green.R, green.G, green.B), 90) };
        area.Points.Add(new Point(0, height));
        for (int i = 0; i < values.Count; i++)
        {
            var point = new Point(i * width / Math.Max(1, values.Count - 1), height * (0.96 - 0.92 * values[i] / peak));
            line.Points.Add(point);
            area.Points.Add(point);
        }
        area.Points.Add(new Point(width, height));
        return new Canvas { Height = height, Width = width, Children = { area, line }, ClipToBounds = true };
    }

    FrameworkElement ActionTiles()
    {
        var g = new System.Windows.Controls.Primitives.UniformGrid { Columns = 3 };
        g.Children.Add(Tile("Добавить", "plus", SidePanel.Add, "Добавить подписку или серверы"));
        g.Children.Add(Tile("Настройки", "gearshape", SidePanel.Settings, "Настройки"));
        g.Children.Add(Tile("Серверы", "list.bullet", SidePanel.Servers, "Список серверов"));
        var bar = Card(g, 12, new Thickness(4));
        bar.MinHeight = 64;
        return bar;
    }

    FrameworkElement Tile(string title, string glyph, SidePanel panel, string tip)
    {
        var sel = m.Panel == panel;
        var content = V(4, PanelSymbols.Draw(glyph, 16, sel ? "Text" : "Text2"), T(title, 11, sel ? FontWeights.SemiBold : FontWeights.Medium, sel ? "Text" : "Text2"));
        ((TextBlock)content.Children[1]).HorizontalAlignment = HorizontalAlignment.Center;
        var b = Flat(content, () => TogglePanel(panel), tip, new Thickness(0, 9, 0, 9));
        if (sel) { b.Background = B("Selected"); }
        return new Border { CornerRadius = new CornerRadius(8), Margin = new Thickness(1), BorderThickness = new Thickness(1),
            BorderBrush = sel ? Hex("#731FB58F") : Brushes.Transparent, Child = b };
    }

    FrameworkElement MainButton()
    {
        if (m.ServiceStage is { } stage)
            return new Button { Style = S("BigButton"), Content = L.T(stage), IsEnabled = false, Background = B("Brand") };
        if (m.DaemonReachable && !m.DaemonOutdated && m.Status.State == TunnelState.Failed)
        {
            var actions = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2, IsEnabled = !m.Busy };
            actions.Children.Add(Btn("Повторить подключение", () => _ = m.Connect(), primary: true));
            actions.Children.Add(Btn("Отключить", () => _ = m.Disconnect()));
            return actions;
        }
        var b = new Button { Style = S("BigButton") };
        if (!m.DaemonReachable || m.DaemonOutdated)
        {
            b.Content = new TextBlock { Text = L.T(m.ServiceInstalled ? "Обновить службу" : "Установить службу"), FontSize = 17, FontWeight = FontWeights.Bold, Foreground = Brushes.White };
            b.Background = B("Brand");
            b.Click += async (_, _) => await m.InstallService();
            b.ToolTip = "Нужны права администратора: служба держит VPN и меняет сеть";
        }
        else
        {
            var heldBlock = m.Status.State == TunnelState.Stopped && m.Status.EmergencyBlock;
            var canDisconnect = m.IsConnected || heldBlock;
            var text = m.Busy ? (canDisconnect ? "Отключение…" : "Подключение…") : (canDisconnect ? "Отключить" : "Подключить");
            // Цвет задаём самому TextBlock: общий стиль TextBlock иначе перекрасит текст в белый.
            b.Content = new TextBlock { Text = L.T(text), FontSize = 17, FontWeight = FontWeights.Bold, Foreground = canDisconnect ? B("Bg") : Brushes.White };
            b.Background = canDisconnect ? Hex("#EDEDED") : B("On");
            b.Click += async (_, _) => await (heldBlock ? m.Disconnect() : m.Toggle());
        }
        b.IsEnabled = !m.Busy;
        return b;
    }

    // MARK: перетаскивание

    async void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] files)
        {
            foreach (var f in files)
            {
                try
                {
                    if (QR.ImageExtensions.Contains(System.IO.Path.GetExtension(f).ToLowerInvariant())) { await m.ImportQR(QR.FromFile(f)); continue; }
                    var bytes = await File.ReadAllBytesAsync(f);
                    if (bytes.Length > 16 << 20) { m.Message = "Файл слишком большой"; continue; }
                    await m.ImportText(System.Text.Encoding.UTF8.GetString(bytes));
                }
                catch (Exception ex) { m.Message = ex.Message; }
            }
        }
        else if (e.Data.GetData(DataFormats.UnicodeText) is string text) await m.ImportText(text);
    }
}

/// Три плитки одинаковой ширины.
public sealed class UniformGrid3 : System.Windows.Controls.Primitives.UniformGrid
{
    public UniformGrid3(params UIElement[] items)
    {
        Columns = items.Length;
        foreach (var i in items) Children.Add(i);
        if (items.LastOrDefault() is FrameworkElement last) last.Margin = new Thickness(0);
    }
}
