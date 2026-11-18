using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Tutun.Core;
using static Tutun.App.UI;

namespace Tutun.App;

/// Небольшие отдельные окна из «Ещё»: журнал службы, статистика, соединения.
public static class InfoWindows
{
    static Window Make(Window owner, string title, double w, double h)
    {
        var win = new Window
        {
            Title = L.T(title), Owner = owner, Width = w, Height = h, Background = B("Bg"),
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false,
        };
        win.SourceInitialized += (_, _) => SystemIntegration.DarkTitleBar(new System.Windows.Interop.WindowInteropHelper(win).Handle);
        return win;
    }

    public static void ShowLog(Window owner)
    {
        var m = AppModel.Shared;
        var w = Make(owner, "Журнал", 760, 520);
        var box = new TextBox
        {
            IsReadOnly = true, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(12),
        };
        var filter = new TextBox();
        void Fill()
        {
            var text = string.Join(Environment.NewLine, m.Status.Log.Where(line => line.Contains(filter.Text, StringComparison.CurrentCultureIgnoreCase)));
            if (!m.DaemonReachable) text = "Служба не отвечает. Полный журнал: " + Paths.Log;
            if (box.Text == text) return;
            var atEnd = box.VerticalOffset + box.ViewportHeight >= box.ExtentHeight - 4;
            box.Text = text;
            if (atEnd) box.ScrollToEnd();
        }
        Fill(); box.ScrollToEnd();
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        t.Tick += (_, _) => Fill();
        t.Start();
        w.Closed += (_, _) => t.Stop();
        filter.TextChanged += (_, _) => Fill();
        var bar = V(4, T("Найти в журнале", 12, color: "Text2"), filter,
            H(8, Dropdown([("error","Ошибки"), ("warning","Предупреждения"), ("info","Подробно"), ("debug","Отладка")], m.Settings.LogLevel,
                value => { var before = m.Settings.Copy(); m.Settings.LogLevel = value; m.SettingsEdited(before); }), Btn("Открыть файл", () => SystemIntegration.OpenFile(Paths.Log)),
                 Btn("Скопировать", () => { if (box.Text.Length > 0) Clipboard.SetText(box.Text); })));
        bar.Margin = new Thickness(12, 12, 12, 0);
        var dock = new DockPanel();
        DockPanel.SetDock(bar, Dock.Top);
        dock.Children.Add(bar); dock.Children.Add(box);
        w.Content = dock;
        w.Show();
    }

    public static void ShowStats(Window owner)
    {
        var m = AppModel.Shared;
        var w = Make(owner, "Статистика", 460, 560);
        var p = new StackPanel { Margin = new Thickness(18) };
        void Line(string k, string v) => p.Children.Add(Row(T(k, 13, color: "Text2"), T(v, 13, FontWeights.SemiBold)));
        p.Children.Add(Header("Через VPN"));
        string DayKey(DateTime day) => day.ToString("yyyy-MM-dd", System.Globalization.CultureInfo.InvariantCulture);
        var today = DateTime.Today;
        var current = m.Days.GetValueOrDefault(DayKey(today));
        Line("Сегодня", Format.Bytes((current?.Down ?? 0) + (current?.Up ?? 0)));
        Line("Этот месяц", Format.Bytes(m.Days.Where(pair => pair.Key.StartsWith(DayKey(today)[..7])).Sum(pair => pair.Value.Down + pair.Value.Up)));
        Line("Текущая сессия", Format.Bytes(m.Status.Downlink + m.Status.Uplink));
        p.Children.Add(Header("По дням, 30 дней"));
        var chart = new System.Windows.Controls.Primitives.UniformGrid { Rows = 1, Height = 132 };
        var days = Enumerable.Range(0, 30).Select(i => today.AddDays(i - 29)).ToList();
        var peak = days.Max(day => m.Days.TryGetValue(DayKey(day), out var d) ? d.Down + d.Up : 0);
        if (peak == 0) p.Children.Add(Hint("Пока пусто"));
        else
        {
            foreach (var day in days)
            {
                var d = m.Days.GetValueOrDefault(DayKey(day)) ?? new DayStat();
                var bars = new StackPanel { VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(1),
                    ToolTip = $"{day:d}  ↓ {Format.Bytes(d.Down)}  ↑ {Format.Bytes(d.Up)}" };
                bars.Children.Add(new Border { Background = B("Brand"), Height = 128d * d.Up / peak });
                bars.Children.Add(new Border { Background = B("On"), Height = 128d * d.Down / peak });
                chart.Children.Add(bars);
            }
            p.Children.Add(chart);
            p.Children.Add(H(12, T("Загрузка", 12, color: "On"), T("Отдача", 12, color: "Brand")));
        }
        p.Children.Add(Header("По серверам"));
        if (m.ServerUsage.Count == 0) p.Children.Add(Hint("Пока пусто"));
        foreach (var (name, bytes) in m.ServerUsage.OrderByDescending(kv => kv.Value).Take(12)) Line(name, Format.Bytes(bytes));
        p.Children.Add(Header("IP-адрес"));
        var vpn = T("", 13); var direct = T("", 13);
        p.Children.Add(Row(T("Через VPN", 13), vpn));
        p.Children.Add(Row(T("Без VPN", 13), direct));
        async Task CheckIP()
        {
            await m.CheckIP();
            vpn.Text = m.IpVPN is { } v ? $"{v.Ip} · {v.Country}" : "—";
            direct.Text = m.IpDirect is { } d ? $"{d.Ip} · {d.Country}" : "—";
        }
        p.Children.Add(Btn("Проверить", () => _ = CheckIP()));
        var reset = Btn("Сбросить статистику", () => { m.ResetStats(); w.Close(); });
        reset.Foreground = B("Bad"); reset.Margin = new Thickness(0, 16, 0, 0); reset.HorizontalAlignment = HorizontalAlignment.Left;
        p.Children.Add(reset);
        w.Content = Scroll(p);
        w.Show();
        _ = CheckIP();
    }

    /// Активные соединения из clash API sing-box (только в режиме «Весь трафик»).
    public static void ShowConnections(Window owner)
    {
        var m = AppModel.Shared;
        var w = Make(owner, "Соединения", 760, 520);
        var list = new StackPanel { Margin = new Thickness(14) };
        var secret = Convert.ToHexStringLower(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes("clash" + m.Applied.Hwid))[..12]);
        var filter = new TextBox();
        bool loading = false;
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", secret);
        var endpoint = $"http://127.0.0.1:{Paths.ClashPort}/connections";
        var info = T("", 12, color: "Text2");
        async Task CloseConnection(string suffix)
        {
            try
            {
                using var response = await client.DeleteAsync(endpoint + suffix);
                response.EnsureSuccessStatusCode();
                await Fill();
            }
            catch (Exception e) { info.Text = e.Message; }
        }
        var closeAll = new Button { Style = S("TButton"), Content = L.T("Закрыть все") };
        closeAll.Click += async (_, _) => await CloseConnection("");
        async Task Fill()
        {
            if (loading) return;
            closeAll.IsEnabled = false;
            if (!m.IsConnected || m.Applied.Mode != ConnectionMode.Tun)
            {
                list.Children.Clear();
                list.Children.Add(Hint("Список виден при подключённом VPN в режиме «Весь трафик Windows»."));
                return;
            }
            try
            {
                loading = true;
                var o = Json.ParseObject(await client.GetStringAsync(endpoint));
                var conns = (o.Arr("connections") ?? []).OfType<JsonObject>().ToList();
                list.Children.Clear();
                closeAll.IsEnabled = conns.Count > 0;
                int shown = 0;
                foreach (var c in conns.OrderByDescending(c => c.Str("start")))
                {
                    var meta = c.Obj("metadata");
                    var host = meta.Str("host") is { Length: > 0 } hst ? hst : meta.Str("destinationIP");
                    var proc = Path.GetFileName(meta.Str("processPath") ?? "");
                    if (proc.Equals("xray.exe", StringComparison.OrdinalIgnoreCase) || proc.Equals("sing-box.exe", StringComparison.OrdinalIgnoreCase)) continue;
                    if (!(host ?? "").Contains(filter.Text, StringComparison.CurrentCultureIgnoreCase) && !proc.Contains(filter.Text, StringComparison.CurrentCultureIgnoreCase)) continue;
                    shown++;
                    var id = c.Str("id");
                    var close = IconButton("xmark", () => _ = CloseConnection("/" + Uri.EscapeDataString(id!)), "Закрыть соединение");
                    close.IsEnabled = !string.IsNullOrEmpty(id);
                    var chains = string.Join(" → ", (c.Arr("chains") ?? []).Select(x => x?.ToString()));
                    var row = Row(V(1, T($"{host}:{meta.Str("destinationPort")}", 13), T($"{proc} · {meta.Str("network")} · {chains}", 11, color: "Text3")),
                                  T($"↓ {Format.Bytes(long.TryParse(c.Str("download"), out var dl) ? dl : 0)}   ↑ {Format.Bytes(long.TryParse(c.Str("upload"), out var up) ? up : 0)}", 12, color: "Text2"), close);
                    row.Margin = new Thickness(0, 6, 0, 0);
                    list.Children.Add(row);
                }
                info.Text = L.F("%@ активных", shown);
            }
            catch (Exception e) { list.Children.Clear(); list.Children.Add(Hint("Нет ответа от sing-box: " + e.Message)); }
            finally { loading = false; }
        }
        var t = new DispatcherTimer { Interval = TimeSpan.FromSeconds(2) };
        t.Tick += async (_, _) => await Fill();
        t.Start();
        w.Closed += (_, _) => { t.Stop(); client.Dispose(); };
        var top = V(6, T("Сайт или приложение", 12, color: "Text2"), filter, Row(info, closeAll));
        top.Margin = new Thickness(14, 12, 14, 0);
        filter.TextChanged += async (_, _) => await Fill();
        var dock = new DockPanel(); DockPanel.SetDock(top, Dock.Top);
        dock.Children.Add(top); dock.Children.Add(Scroll(list));
        w.Content = dock;
        w.Show();
        _ = Fill();
    }
}
