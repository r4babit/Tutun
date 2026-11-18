using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using Tutun.Core;

namespace Tutun.App;

/// Небольшие строительные блоки интерфейса (код вместо XAML: списки перестраиваются целиком).
public static class UI
{
    /// Включены ли анимации: по настройке Tutun или, по умолчанию, как в Windows.
    public static bool Animations => UiPrefs.Current.Animations ?? SystemParameters.ClientAreaAnimation;

    public static Brush B(string key) => (Brush)Application.Current.Resources[key];
    public static Brush Hex(string hex) { var b = (Brush)new BrushConverter().ConvertFromString(hex)!; b.Freeze(); return b; }
    public static Style S(string key) => (Style)Application.Current.Resources[key];

    public static TextBlock T(string text, double size = 14, FontWeight? weight = null, string color = "Text", bool wrap = false) => new()
    {
        Text = L.T(text), FontSize = size, FontWeight = weight ?? FontWeights.Normal, Foreground = B(color),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap, TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
    };

    public static Viewbox Icon(string symbol, double size = 14, string color = "Text2") => PanelSymbols.Draw(symbol, size, color);

    public static Border Card(UIElement child, double radius = 12, Thickness? padding = null, bool line = true) => new()
    {
        Background = B("Card"), BorderBrush = line ? B("Line") : Brushes.Transparent, BorderThickness = new Thickness(line ? 1 : 0),
        CornerRadius = new CornerRadius(radius), Padding = padding ?? new Thickness(12), Child = child,
    };

    public static StackPanel V(double spacing, params UIElement[] items)
    {
        var p = new StackPanel();
        for (int i = 0; i < items.Length; i++)
        {
            if (items[i] is FrameworkElement fe && i > 0) fe.Margin = new Thickness(fe.Margin.Left, fe.Margin.Top + spacing, fe.Margin.Right, fe.Margin.Bottom);
            p.Children.Add(items[i]);
        }
        return p;
    }

    public static StackPanel H(double spacing, params UIElement[] items)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal };
        for (int i = 0; i < items.Length; i++)
        {
            if (items[i] is FrameworkElement fe) { fe.VerticalAlignment = VerticalAlignment.Center; if (i > 0) fe.Margin = new Thickness(fe.Margin.Left + spacing, fe.Margin.Top, fe.Margin.Right, fe.Margin.Bottom); }
            p.Children.Add(items[i]);
        }
        return p;
    }

    /// Строка: слева растягивается, справа — по содержимому.
    public static Grid Row(UIElement left, params UIElement[] right)
    {
        var g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.Children.Add(left);
        for (int i = 0; i < right.Length; i++)
        {
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            Grid.SetColumn(right[i], i + 1);
            if (right[i] is FrameworkElement fe) fe.VerticalAlignment = VerticalAlignment.Center;
            g.Children.Add(right[i]);
        }
        if (left is FrameworkElement l) l.VerticalAlignment = VerticalAlignment.Center;
        return g;
    }

    public static Button Flat(UIElement content, Action click, string? tip = null, Thickness? padding = null)
    {
        var b = new Button { Style = S("Flat"), Content = content, Padding = padding ?? new Thickness(0), ToolTip = tip == null ? null : L.T(tip) };
        b.Click += (_, e) => { e.Handled = true; click(); };
        return b;
    }

    public static Button IconButton(string glyph, Action click, string tip, double size = 14)
    {
        var icon = Icon(glyph, size);
        var b = Flat(icon, click, tip);
        b.Style = S("IconFlat");
        b.Width = 30; b.Height = 30;
        b.MouseEnter += (_, _) => PanelSymbols.SetTint(icon, "Text");
        b.MouseLeave += (_, _) => PanelSymbols.SetTint(icon, "Text2");
        return b;
    }

    public static Button Btn(string text, Action click, bool primary = false, string? tip = null)
    {
        var b = new Button { Style = S("TButton"), Content = L.T(text), ToolTip = tip == null ? null : L.T(tip) };
        if (primary) { b.Background = B("On"); b.Foreground = B("Bg"); b.BorderBrush = B("On"); }
        b.Click += (_, _) => click();
        return b;
    }

    static readonly Dictionary<string, System.Windows.Media.Imaging.BitmapImage?> FlagCache = new();

    static System.Windows.Media.Imaging.BitmapImage? FlagImage(string code)
    {
        var c = code.ToLowerInvariant() == "uk" ? "gb" : code.ToLowerInvariant();
        if (FlagCache.TryGetValue(c, out var img)) return img;
        try
        {
            var uri = new Uri($"pack://application:,,,/Assets/flags/{c}.png");
            if (Application.GetResourceStream(uri) == null) throw new IOException();
            img = new System.Windows.Media.Imaging.BitmapImage();
            img.BeginInit(); img.UriSource = uri; img.CacheOption = System.Windows.Media.Imaging.BitmapCacheOption.OnLoad; img.EndInit();
            img.Freeze();
        }
        catch { img = null; }
        FlagCache[c] = img;
        return img;
    }

    /// Флаг страны картинкой (Windows не рисует эмодзи-флаги); если картинки нет — код страны на плашке.
    public static Border CountryBadge(string? code, double size = 26)
    {
        if (code is { Length: 2 } && FlagImage(code) is { } flag)
        {
            var w = size * 1.35;
            // Картинка — фоном рамки: так скругляются углы (Border не обрезает дочерний элемент).
            var b = new Border
            {
                Width = w, Height = size, CornerRadius = new CornerRadius(Math.Max(3, size * 0.18)),
                Background = new ImageBrush(flag) { Stretch = Stretch.UniformToFill },
                BorderBrush = Hex("#22FFFFFF"), BorderThickness = new Thickness(0.5),
            };
            RenderOptions.SetBitmapScalingMode(b, BitmapScalingMode.HighQuality);
            return b;
        }
        return CodeBadge(code, size);
    }

    static Border CodeBadge(string? code, double size)
    {
        var text = code is { Length: 2 } ? code : (code == null ? "" : "··");
        var hue = code is { Length: 2 } ? (code[0] * 31 + code[1] * 17) % 360 : 220;
        var color = FromHsl(hue, 0.45, 0.32);
        return new Border
        {
            Width = size * 1.35, Height = size, CornerRadius = new CornerRadius(5), Background = new SolidColorBrush(color),
            Child = new TextBlock
            {
                Text = text, FontSize = size * 0.42, FontWeight = FontWeights.Bold, Foreground = Brushes.White,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            },
        };
    }

    public static Border GlyphBadge(string glyph, double size, string color = "Busy") => new()
    {
        Width = size * 1.35, Height = size, Child = Icon(glyph, size * 0.75, color),
    };

    static Color FromHsl(double h, double s, double l)
    {
        double c = (1 - Math.Abs(2 * l - 1)) * s, x = c * (1 - Math.Abs(h / 60 % 2 - 1)), m = l - c / 2;
        (double r, double g, double b) = h switch { < 60 => (c, x, 0d), < 120 => (x, c, 0d), < 180 => (0d, c, x), < 240 => (0d, x, c), < 300 => (x, 0d, c), _ => (c, 0d, x) };
        return Color.FromRgb((byte)((r + m) * 255), (byte)((g + m) * 255), (byte)((b + m) * 255));
    }

    /// «Уровень сигнала» по задержке: 3 полосы — быстро, 2 — нормально, 1 — медленно.
    public static FrameworkElement SignalBars(int? ms)
    {
        int bars = ms == null ? -1 : ms < 0 ? 0 : ms < 300 ? 3 : ms < 800 ? 2 : 1;
        var color = bars switch { 3 => "On", 2 => "Busy", 1 => "Bad", _ => "Off" };
        var p = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Height = 13 };
        for (int i = 1; i <= 3; i++)
            p.Children.Add(new Border
            {
                Width = 3, Height = 4 + i * 3, CornerRadius = new CornerRadius(1), Margin = new Thickness(0, 0, 2, 0), VerticalAlignment = VerticalAlignment.Bottom,
                Background = i <= bars ? B(color) : Hex("#33FFFFFF"),
            });
        return p;
    }

    /// Задержка: полоски и число, прижаты вправо.
    public static FrameworkElement Latency(int? ms)
    {
        var text = ms == null ? "—" : ms < 0 ? "нет ответа" : L.F("%@ мс", ms);
        var t = T(text, 13, color: ms is < 0 ? "Bad" : "Text2");
        var p = H(5, SignalBars(ms), t);
        p.HorizontalAlignment = HorizontalAlignment.Right;
        return new Border { Width = 108, Child = p, Padding = new Thickness(0, 0, 4, 0) };
    }

    public static Border Chip(string text, string color = "On") => new()
    {
        Background = new SolidColorBrush(((SolidColorBrush)B(color)).Color) { Opacity = 0.15 },
        CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 1, 6, 1),
        Child = T(text, 11, FontWeights.Medium, color),
    };

    public static Border Banner(string text, string color = "Busy")
    {
        var c = ((SolidColorBrush)B(color)).Color;
        return new Border
        {
            Background = new SolidColorBrush(c) { Opacity = 0.12 }, CornerRadius = new CornerRadius(10), Padding = new Thickness(10),
            Child = H(8, Icon("exclamationmark.triangle", 14, color), T(text, 13, color: color, wrap: true)),
        };
    }

    /// Выпадающий список в стиле Tutun (тёмная карточка, всплывающий список под ней).
    public static FrameworkElement Dropdown<TV>((TV value, string label)[] items, TV current, Action<TV> onChange) where TV : notnull
    {
        var label = T(items.FirstOrDefault(i => i.value.Equals(current)).label ?? current.ToString() ?? "", 13);
        var face = Row(label, Icon("chevron.down", 10));
        var button = new Button { Style = S("Flat"), Content = face, Padding = new Thickness(12, 8, 10, 8), HorizontalContentAlignment = HorizontalAlignment.Stretch };
        var host = new Border { Background = B("Card"), BorderBrush = B("Line"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9), Child = button };
        var list = new StackPanel();
        // Свой скролл у списка: колесо мыши над списком крутит его, а не страницу настроек.
        var listScroll = new ScrollViewer
        {
            Content = list, MaxHeight = 320, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Focusable = false,
        };
        listScroll.PreviewMouseWheel += (_, e) =>
        {
            listScroll.ScrollToVerticalOffset(listScroll.VerticalOffset - e.Delta / 3.0);
            e.Handled = true;
        };
        var popup = new Popup
        {
            PlacementTarget = host, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = true, VerticalOffset = 4,
            Child = new Border
            {
                Background = B("Card"), BorderBrush = B("Line"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(9), Padding = new Thickness(4),
                Child = listScroll, Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 14, ShadowDepth = 3, Opacity = 0.4 },
            },
        };
        foreach (var (value, text) in items)
        {
            var sel = value.Equals(current);
            var row = Row(T(text, 13, sel ? FontWeights.SemiBold : FontWeights.Normal), sel ? Icon("checkmark", 12, "On") : new Border());
            var opt = Flat(row, () =>
            {
                popup.IsOpen = false;
                label.Text = L.T(text);
                current = value;
                onChange(value);
            }, null, new Thickness(10, 7, 10, 7));
            list.Children.Add(opt);
        }
        host.SizeChanged += (_, _) => ((Border)popup.Child).MinWidth = host.ActualWidth;
        // Повторное нажатие на сам список закрывает его. Popup со StaysOpen=false закрывается уже на нажатии мыши,
        // поэтому запоминаем это и не открываем его снова тем же щелчком.
        var closedAt = DateTime.MinValue;
        popup.Closed += (_, _) => closedAt = DateTime.UtcNow;
        button.Click += (_, _) =>
        {
            if (DateTime.UtcNow - closedAt < TimeSpan.FromMilliseconds(300)) return;
            popup.IsOpen = !popup.IsOpen;
        };
        // Пока список открыт, страница под ним не прокручивается.
        popup.Opened += (_, _) =>
        {
            if (FindScroll(host) is { } page) page.PreviewMouseWheel += Block;
            // Открывается на выбранном пункте.
            listScroll.ScrollToTop();
            var i = Array.FindIndex(items, it => it.value.Equals(current));
            if (i >= 0 && i < list.Children.Count) list.Children[i].Dispatcher.BeginInvoke(() => ((FrameworkElement)list.Children[i]).BringIntoView());
        };
        popup.Closed += (_, _) =>
        {
            if (FindScroll(host) is { } page) page.PreviewMouseWheel -= Block;
        };
        void Block(object? sender, System.Windows.Input.MouseWheelEventArgs e)
        {
            // Колесо над самим списком обрабатывает его скролл; над страницей — список закрывается, страница не уезжает из-под него.
            if (popup.IsOpen && !popup.Child.IsMouseOver) { e.Handled = true; popup.IsOpen = false; }
        }
        var grid = new Grid();
        grid.Children.Add(host);
        grid.Children.Add(popup);
        return grid;
    }

    static ScrollViewer? FindScroll(DependencyObject d)
    {
        for (var p = VisualTreeHelper.GetParent(d); p != null; p = VisualTreeHelper.GetParent(p))
            if (p is ScrollViewer sv) return sv;
        return null;
    }

    public static TextBlock Hint(string text) => T(text, 12, color: "Text3", wrap: true);

    public static TextBlock Header(string text) { var t = T(L.T(text).ToUpper(L.Culture), 11, FontWeights.SemiBold, "Text3"); t.Margin = new Thickness(4, 14, 0, 6); return t; }

    public static ScrollViewer Scroll(UIElement content) => new()
    {
        Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        Focusable = false, PanningMode = PanningMode.VerticalOnly,
    };

    public static ContextMenu Menu(params (string? title, Action? action)[] items)
    {
        var m = new ContextMenu();
        foreach (var (title, action) in items)
        {
            if (title == null) { m.Items.Add(new Separator()); continue; }
            var mi = new MenuItem { Header = L.T(title) };
            if (action != null) mi.Click += (_, _) => action();
            m.Items.Add(mi);
        }
        return m;
    }

    /// Простой запрос строки (переименование и т.п.).
    public static string? Prompt(Window owner, string title, string initial)
    {
        var box = new TextBox { Text = initial, Margin = new Thickness(0, 10, 0, 14) };
        string? result = null;
        var w = new Window
        {
            Title = L.T(title), Owner = owner, Width = 380, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = B("Bg"), ShowInTaskbar = false,
        };
        var ok = Btn("Сохранить", () => { result = box.Text; w.Close(); }, primary: true);
        var cancel = Btn("Отмена", () => w.Close());
        w.Content = new Border { Padding = new Thickness(16), Child = V(0, T(title, 14, FontWeights.SemiBold), box, Row(new Border(), cancel, new Border { Width = 8 }, ok)) };
        w.SourceInitialized += (_, _) => SystemIntegration.DarkTitleBar(new System.Windows.Interop.WindowInteropHelper(w).Handle);
        box.KeyDown += (_, e) => { if (e.Key == Key.Enter) { result = box.Text; w.Close(); } };
        w.Loaded += (_, _) => { box.Focus(); box.SelectAll(); };
        w.ShowDialog();
        return result;
    }
}

/// Названия стран на языке интерфейса: русский — свой список, остальные — английские названия Windows.
public static class Loc
{
    public static string Country(string code)
    {
        if (L.Code is "ru" or "uk" || code.Length != 2) return L.T(Countries.Name(code));
        try { return new System.Globalization.RegionInfo(code == "UK" ? "GB" : code).EnglishName; } catch { return code; }
    }
}

public static class StatusText
{
    public static string Title(DaemonStatus s, bool reachable)
    {
        if (!reachable) return "Служба не запущена";
        if (s.EmergencyBlock && s.State == TunnelState.Stopped) return "Трафик вне VPN заблокирован";
        return s.State switch
        {
            TunnelState.Running => s.Healthy == true ? "Подключено" : s.Healthy == false ? "Нет связи с сервером" : "Подключение…",
            TunnelState.Starting => "Подключение…",
            TunnelState.Reconnecting => s.EmergencyBlock ? "Переподключение · интернет заблокирован" : "Переподключение…",
            TunnelState.Failed => "Ошибка подключения",
            _ => "Отключено",
        };
    }

    public static string Color(DaemonStatus s, bool reachable)
    {
        if (!reachable) return "Off";
        return s.State switch
        {
            TunnelState.Running => s.Healthy == true ? "On" : "Busy",
            TunnelState.Starting or TunnelState.Reconnecting => "Busy",
            TunnelState.Failed => "Bad",
            _ => "Off",
        };
    }
}
