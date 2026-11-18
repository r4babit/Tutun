using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Tutun.Core;
using static Tutun.App.UI;

namespace Tutun.App;

/// Правая панель: «Самый быстрый», «Избранное», подписки → страны по алфавиту → серверы.
/// Клик по стране — самый быстрый сервер страны, стрелка — её серверы, клик по серверу — подключиться.
public sealed class ServerList
{
    readonly MainWindow owner;
    readonly bool compact;
    readonly SubscriptionReorder? reorder;
    readonly AppModel m = AppModel.Shared;
    readonly StackPanel list = new() { Margin = new Thickness(10, 12, 14, 12) };
    readonly HashSet<string> expanded = new();
    /// Что раскрыли/свернули последним — только это анимируем (0,18 с, ease-out), остальной список не дёргается.
    string? animKey;
    string signature = "";
    public FrameworkElement View { get; }

    public ServerList(MainWindow owner, bool compact = false)
    {
        this.owner = owner;
        this.compact = compact;
        if (!compact) reorder = new SubscriptionReorder(list, m);
        View = Scroll(list);
    }

    string Signature()
    {
        var sb = new StringBuilder();
        sb.Append(m.Servers.Count).Append('|').Append(m.Hidden.Count).Append('|').Append(m.Testing).Append(m.SpeedTesting).Append(m.UpdatingSubs);
        sb.Append(m.Settings.AutoSelect).Append(m.Settings.SelectedCountry).Append(m.Settings.SelectedServerID).Append(string.Join(",", m.Settings.FavoriteCountries));
        sb.Append(m.IsConnected).Append(m.CurrentServer?.Id).Append(string.Join(",", expanded));
        sb.Append(UiPrefs.Current.FavoritesCollapsed).Append(UiPrefs.Current.ManualListMode).Append(UiPrefs.Current.ManualListSort);
        foreach (var s in m.Subscriptions) sb.Append(s.ListMode).Append(s.ListSort).Append(s.Id).Append(s.Name).Append(s.Collapsed).Append(s.Enabled);
        foreach (var (k, v) in m.Pings) sb.Append(k).Append(v);
        foreach (var s in m.Servers) if (s.Favorite) sb.Append(s.Id);
        foreach (var (k, v) in m.Speeds) sb.Append(k).Append((int)v);
        sb.Append(string.Join(",", m.Settings.ServerRenames.Values)).Append(string.Join(",", m.CollapsedGroups));
        return sb.ToString();
    }

    public void Rebuild(bool force = false)
    {
        var sig = Signature();
        if (!force && sig == signature) return;
        signature = sig;
        list.Children.Clear();
        list.Children.Add(FastestRow());

        var favCountries = m.FavoriteCountryList;
        var favServers = m.FavoriteServerList;
        if (favCountries.Count > 0 || favServers.Count > 0)
        {
            var h = H(6, Icon("star.fill", 11, "Busy"), T("Избранное", 12, FontWeights.SemiBold, "Text2"));
            h.Margin = new Thickness(12, 12, 0, 4);
            var prefs = UiPrefs.Current;
            h.Children.Insert(0, Chevron("chevron.right", 10, prefs.FavoritesCollapsed ? 0 : 90, "favorites"));
            h.Children.Add(T((favCountries.Count + favServers.Count).ToString(), 11, color: "Text3"));
            list.Children.Add(Flat(h, () => { prefs.FavoritesCollapsed = !prefs.FavoritesCollapsed; prefs.Save(); m.NotifyChanged(); }));
            if (!prefs.FavoritesCollapsed)
            {
            foreach (var c in favCountries) AddCountry(c, "fav|" + c.Id);
            foreach (var s in favServers) list.Children.Add(ServerRow(s, bigBadge: true));
            }
        }

        var groups = m.ServerGroups;
        foreach (var g in groups)
        {
            var sub = m.Subscriptions.FirstOrDefault(s => s.Id == g.SubscriptionId);
            var mode = sub?.ListMode ?? UiPrefs.Current.ManualListMode;
            var sort = sub?.ListSort ?? UiPrefs.Current.ManualListSort;
            var ids = g.Countries.SelectMany(c => c.Servers).Select(s => s.Id).ToHashSet();
            var original = m.UsableServers.Where(s => ids.Contains(s.Id)).ToList();
            List<Server> Ordered(IEnumerable<Server> items) => sort switch {
                "provider" => items.ToList(),
                "ping" => items.OrderBy(s => m.Pings.TryGetValue(s.Id, out var ms) && ms >= 0 ? ms : int.MaxValue).ThenBy(m.CleanName).ToList(),
                _ => items.OrderBy(m.CleanName, StringComparer.CurrentCultureIgnoreCase).ToList()
            };
            list.Children.Add(GroupHeader(g, sub, mode, sort, original));
            if (!m.IsCollapsed(g))
            {
                var from = list.Children.Count;
                if (mode == "list") foreach (var server in Ordered(original)) list.Children.Add(ServerRow(server, true));
                else
                {
                    var countries = g.Countries.OrderBy(c => c.Id == "??");
                    countries = sort switch {
                        "count" => countries.ThenByDescending(c => c.Servers.Count),
                        "ping" => countries.ThenBy(c => c.BestPing ?? int.MaxValue),
                        "provider" => countries.ThenBy(c => original.FindIndex(s => (s.CountryCode ?? "??") == c.Id)),
                        _ => countries.ThenBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase)
                    };
                    foreach (var c in countries)
                        AddCountry(c with { Servers = Ordered(original.Where(s => (s.CountryCode ?? "??") == c.Id)) }, g.Id + "|" + c.Id);
                }
                if (animKey == g.Id) for (int i = from; i < list.Children.Count; i++) FadeIn(list.Children[i]);
            }
        }
        if (groups.Count == 0)
        {
            var empty = V(8,
                Icon("network", 34, "Text3"),
                Centered(T("Серверов пока нет", 16, FontWeights.SemiBold)),
                Centered(T("Нажмите «Добавить» и вставьте ссылку на подписку", 13, color: "Text2", wrap: true)),
                Centered(Btn("Добавить подписку", () => owner.SetPanel(SidePanel.Add), primary: true)));
            empty.Margin = new Thickness(30, 50, 30, 0);
            list.Children.Add(empty);
        }
        animKey = null;
    }


    void FadeIn(UIElement e)
    {
        if (!Animations) return;
        var a = new System.Windows.Media.Animation.DoubleAnimation(0, 1, TimeSpan.FromSeconds(0.18))
        { EasingFunction = new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut } };
        e.BeginAnimation(UIElement.OpacityProperty, a);
    }

    /// Шеврон с поворотом: у только что переключённого — плавный поворот на 90° (0,18 с, ease-out).
    Viewbox Chevron(string glyph, double size, double angle, string key)
    {
        var t = Icon(glyph, size, "Text2");
        Rotate(t, angle, key);
        return t;
    }

    void Rotate(FrameworkElement t, double angle, string key)
    {
        var rt = new RotateTransform(angle);
        t.RenderTransformOrigin = new Point(0.5, 0.5);
        t.RenderTransform = rt;
        if (animKey != key || !Animations) return;
        var from = angle == 0 ? (key.StartsWith("c|") ? 180 : 90) : 0;
        rt.BeginAnimation(RotateTransform.AngleProperty, new System.Windows.Media.Animation.DoubleAnimation(from, angle, TimeSpan.FromSeconds(0.18))
        { EasingFunction = new System.Windows.Media.Animation.CubicEase { EasingMode = System.Windows.Media.Animation.EasingMode.EaseOut } });
    }

    static FrameworkElement Centered(FrameworkElement e) { e.HorizontalAlignment = HorizontalAlignment.Center; if (e is TextBlock t) t.TextAlignment = TextAlignment.Center; return e; }

    FrameworkElement FastestRow()
    {
        var sel = m.Settings.AutoSelect;
        var content = H(12, GlyphBadge("bolt.fill", 22), V(1, T("Самый быстрый", 15, sel ? FontWeights.SemiBold : FontWeights.Medium),
                                                         T("Tutun выберет сам и переключит при обрыве", 12, color: "Text3")));
        var b = Flat(content, () => _ = m.SelectFastest(), null, new Thickness(12, 9, 12, 9));
        return Selected(b, sel);
    }

    static FrameworkElement Selected(Button b, bool sel)
    {
        if (!sel) return b;
        b.Background = B("Selected");
        return new Border { BorderBrush = Hex("#5A1FB58F"), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Child = b };
    }

    FrameworkElement GroupHeader(ServerGroup g, Subscription? sub, string mode, string sort, List<Server> servers)
    {
        var open = !m.IsCollapsed(g);
        var count = new Border { Background = B("Bg"), CornerRadius = new CornerRadius(8), Padding = new Thickness(6, 1, 6, 1), Child = T(g.Count.ToString(), 11, FontWeights.SemiBold, "Text3") };
        var chev = Chevron("chevron.right", 10, open ? 90 : 0, g.Id); var title = H(8, chev, T(g.Title, 13, FontWeights.SemiBold), count);
        var toggle = Flat(title, () => { animKey = g.Id; m.ToggleCollapsed(g); }, open ? "Свернуть" : "Развернуть", new Thickness(4, 8, 4, 8));
        toggle.HorizontalContentAlignment = HorizontalAlignment.Left;
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        Button ActionIcon(string symbol, string tip, Action action)
        {
            var button = Flat(PanelSymbols.Draw(symbol, 15), action, tip);
            System.Windows.Automation.AutomationProperties.SetName(button, L.T(tip));
            button.Width = 27; button.Height = 30; right.Children.Add(button); return button;
        }
        if (!compact)
        {
            if (sub != null) ActionIcon("arrow.clockwise", "Обновить подписку", () => _ = m.Update(sub.Id)).IsEnabled = !m.UpdatingSubs;
            ActionIcon("speedometer", "Проверить задержку", () => _ = m.PingServers(servers)).IsEnabled = !m.Testing && m.SpeedTesting == null;
            Button? layout = null;
            layout = ActionIcon("arrow.up.arrow.down", "Вид и сортировка", () =>
            {
                var menu = new ContextMenu();
                void Option(string label, string newMode, string newSort, bool selected)
                {
                    var item = new MenuItem { Header = L.T(label), IsChecked = selected };
                    item.Click += (_, _) =>
                    {
                        if (sub != null && m.Subscriptions.FirstOrDefault(x => x.Id == sub.Id) is { } current)
                        { current.ListMode = newMode; current.ListSort = newSort; m.ScheduleSave(); }
                        else if (sub == null)
                        { UiPrefs.Current.ManualListMode = newMode; UiPrefs.Current.ManualListSort = newSort; UiPrefs.Current.Save(); }
                        m.NotifyChanged();
                    };
                    menu.Items.Add(item);
                }
                Option("По странам", "countries", sort, mode != "list");
                Option("Списком", "list", sort == "count" ? "name" : sort, mode == "list");
                menu.Items.Add(new Separator());
                foreach (var (key, label) in new[] { ("name","По имени"), ("count","По числу серверов"), ("ping","По задержке"), ("provider","Как у провайдера") })
                    if (key != "count" || mode != "list") Option(label, mode, key, sort == key);
                menu.PlacementTarget = layout; menu.IsOpen = true;
            });
        }
        if (sub != null) ActionIcon("info.circle", "Информация о подписке", () => SubscriptionInfo.Show(owner, sub.Id));
        var row = Row(toggle, right);
        var card = Card(row, 9, new Thickness(6, 0, 4, 0), line: false);
        card.Margin = new Thickness(0, 10, 0, 2);
        reorder?.Register(toggle, card, g.Id, sub != null);
        return card;
    }

    void AddCountry(Country c, string key)
    {
        var open = expanded.Contains(key);
        list.Children.Add(CountryRow(c, open, () => { animKey = "c|" + c.Id; if (!expanded.Remove(key)) expanded.Add(key); Rebuild(force: true); }));
        if (!open) return;
        foreach (var s in c.Servers)
        {
            var row = ServerRow(s, bigBadge: false);
            if (animKey == "c|" + c.Id) FadeIn(row);
            list.Children.Add(row);
        }
    }

    FrameworkElement CountryRow(Country c, bool open, Action toggle)
    {
        var sel = !m.Settings.AutoSelect && m.Settings.SelectedCountry == c.Id;
        var here = m.IsConnected && m.CurrentServer?.CountryCode == c.Id;
        var text = V(1, T(c.Name, 15, sel || here ? FontWeights.SemiBold : FontWeights.Medium),
                        T(Format.ServersWord(c.Servers.Count) + (here ? " · " + L.T("сейчас здесь") : ""), 12, color: "Text3"));
        var main = Flat(H(12, c.Id == "??" ? GlyphBadge("network", 21, "Text2") : CountryBadge(c.Id, 21), text), () => _ = m.SelectCountry(c.Id),
                        "Подключиться к самому быстрому серверу страны", new Thickness(12, 8, 0, 8));
        main.HorizontalContentAlignment = HorizontalAlignment.Left;
        var star = Star(m.IsFavoriteCountry(c.Id), () => m.ToggleFavoriteCountry(c.Id));
        var chevron = IconButton("chevron.down", toggle, open ? "Скрыть серверы" : "Показать серверы страны", 11);
        chevron.Width = 34; chevron.Height = 42;
        if (chevron.Content is FrameworkElement ct) Rotate(ct, open ? 180 : 0, "c|" + c.Id);
        var row = Row(main, Latency(c.BestPing), star, chevron);
        return Wrap(row, sel, sel);
    }

    FrameworkElement ServerRow(Server s, bool bigBadge)
    {
        var sel = !m.Settings.AutoSelect && m.Settings.SelectedCountry == null && m.Settings.SelectedServerID == s.Id;
        var active = m.IsConnected && m.CurrentServer?.Id == s.Id;
        var nameLine = H(6, T(m.CleanName(s), 13, sel || active ? FontWeights.SemiBold : FontWeights.Normal));
        if (active) nameLine.Children.Add(WithLeft(Chip("сейчас"), 6));
        if (m.SpeedTesting == s.Id) nameLine.Children.Add(WithLeft(T("скорость…", 11, color: "Text3"), 6));
        else if (m.Speeds.TryGetValue(s.Id, out var sp) && sp > 0) nameLine.Children.Add(WithLeft(T(Format.Mbps(sp), 11, color: "Text3"), 6));
        var text = V(1, nameLine, T($"{s.Proto} · {s.Transport}", 11, color: "Text3"));
        UIElement badge = s.CountryCode is { } cc ? CountryBadge(cc, bigBadge ? 19 : 14) : GlyphBadge("network", bigBadge ? 19 : 14, "Text2");
        if (badge is FrameworkElement fb) { fb.Width = 30; fb.HorizontalAlignment = HorizontalAlignment.Center; }
        var main = Flat(H(10, new Border { Width = 30, Child = badge }, text), () => Connect(s), null, new Thickness(12, 6, 0, 6));
        main.HorizontalContentAlignment = HorizontalAlignment.Left;
        var row = Row(main, Latency(m.Pings.TryGetValue(s.Id, out var p) ? p : null), Star(s.Favorite, () => m.ToggleFavorite(s)), new Border { Width = 34 });
        var w = Wrap(row, sel || active, sel);
        var items = new List<(string?, Action?)> { ("Подключиться", () => Connect(s)) };
        if (s.CountryCode is { } code) items.Add((L.F("Самый быстрый в стране «%@»", Loc.Country(code)), () => _ = m.SelectCountry(code)));
        items.AddRange([
            ("Проверить задержку", () => _ = m.PingOne(s)),
            ("Тест скорости", () => _ = m.SpeedTest(s)),
            (null, null),
            (s.Favorite ? "Убрать из избранного" : "В избранное", () => m.ToggleFavorite(s)),
            ("Изменить…", () => ServerEditor.Show(owner, s)),
            ("Переименовать…", () => { if (Prompt(owner, "Имя сервера", m.DisplayName(s)) is { } n) m.Rename(s, n); }),
            ("Скопировать ссылку", () => { if (s.RawLink != null) Clipboard.SetText(s.RawLink); else m.Message = "У сервера нет исходной ссылки"; }),
            ("Показать QR-код", () => { if (s.RawLink != null) QR.Show(owner, m.DisplayName(s), s.RawLink); else m.Message = "У сервера нет исходной ссылки"; }),
            ("Скопировать JSON", () => { Clipboard.SetText(Json.ToJSON(s.Outbound, pretty: true)); m.Message = "JSON сервера скопирован"; }),
            (null, null),
            (s.SubscriptionID == null ? "Удалить" : "Скрыть", () => m.Remove(s)),
        ]);
        w.ContextMenu = Menu(items.ToArray());
        return w;
    }

    void Connect(Server s) => _ = m.Select(s);

    static FrameworkElement WithLeft(FrameworkElement e, double l) { e.Margin = new Thickness(l, 0, 0, 0); return e; }

    static Border Wrap(UIElement row, bool fill, bool outline) => new()
    {
        Child = row, CornerRadius = new CornerRadius(10), Background = fill ? B("Selected") : Brushes.Transparent,
        BorderBrush = outline ? Hex("#5A1FB58F") : Brushes.Transparent, BorderThickness = new Thickness(1), Margin = new Thickness(0, 1, 0, 1),
    };

    static Button Star(bool on, Action toggle)
    {
        var b = Flat(Icon(on ? "star.fill" : "star", 13, on ? "Busy" : "Text3"), toggle, on ? "Убрать из избранного" : "В избранное — будет вверху списка");
        b.Width = 28; b.Height = 30;
        if (!on) b.Opacity = 0.6;
        return b;
    }
}
