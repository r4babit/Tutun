using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using Tutun.Core;
using static Tutun.App.UI;

namespace Tutun.App;

/// Настройки в правой панели. Поля меняют только черновик; «Принять изменения» сохраняет и переподключает.
public sealed class SettingsPanel
{
    enum Section { General, Routes, Network, More, About }

    readonly MainWindow owner;
    readonly AppModel m = AppModel.Shared;
    StackPanel content = new();
    readonly TextBlock heading = T("", 15, FontWeights.SemiBold);
    readonly StackPanel sections = new() { Margin = new Thickness(18, 16, 18, 16) };
    readonly ContentControl applyBar = new();
    readonly ScrollViewer scroll;
    Section section = Section.General;
    readonly TextBlock geoStatus = new() { TextWrapping = TextWrapping.Wrap };
    readonly System.Windows.Shapes.Path geoRing = new() { Width = 28, Height = 28, StrokeThickness = 3, RenderTransformOrigin = new Point(.5,.5) };
    bool geoSpinning;
    Button? geoButton;
    public FrameworkElement View { get; }

    public SettingsPanel(MainWindow owner)
    {
        this.owner = owner;
        scroll = Scroll(sections);
        var g = new Grid();
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        heading.HorizontalAlignment = HorizontalAlignment.Center;
        heading.VerticalAlignment = VerticalAlignment.Center;
        var header = new Border { Height = 42, BorderThickness = new Thickness(0,0,0,1), BorderBrush = B("Line"), Child = heading };
        g.Children.Add(header);
        Grid.SetRow(scroll, 1); g.Children.Add(scroll);
        Grid.SetRow(applyBar, 2); g.Children.Add(applyBar);
        var tabs = Tabs(); Grid.SetRow(tabs, 3); g.Children.Add(tabs);
        View = g;
        UpdateModel.Shared.Changed += () => { if (section == Section.About && View.IsVisible) Rebuild(); };
        m.Changed += RefreshGeoProgress;
        m.Changed += RefreshService;
    }

    readonly Dictionary<Section, Button> tabButtons = new();
    readonly Dictionary<Section, (TextBlock label, string ru)> tabLabels = new();

    FrameworkElement Tabs()
    {
        var grid = new System.Windows.Controls.Primitives.UniformGrid { Columns = 5 };
        foreach (var (sec, title, glyph) in new[] { (Section.General, "Основные", "slider.horizontal.3"), (Section.Routes, "Маршруты", "arrow.triangle.branch"), (Section.Network, "Сеть", "network"), (Section.More, "Ещё", "wrench.and.screwdriver.fill"), (Section.About, "О Tutun", "info.circle.fill") })
        {
            var c = V(3, PanelSymbols.Draw(glyph, 16), T(title, 11, FontWeights.Medium, "Text2"));
            ((TextBlock)c.Children[1]).HorizontalAlignment = HorizontalAlignment.Center;
            tabLabels[sec] = ((TextBlock)c.Children[1], title);
            var b = Flat(c, () => { section = sec; Rebuild(); }, title, new Thickness(0, 7, 0, 7));
            tabButtons[sec] = b;
            grid.Children.Add(new Border { CornerRadius = new CornerRadius(8), BorderThickness = new Thickness(1), Margin = new Thickness(1), Child = b });
        }
        var card = Card(grid, 11, new Thickness(4));
        card.Margin = new Thickness(16, 8, 16, 32);
        return card;
    }

    public void ShowAbout() { section = Section.About; Rebuild(); }

    public void Rebuild()
    {
        foreach (var (sec, b) in tabButtons)
        {
            var selected = sec == section;
            b.Background = selected ? B("Selected") : System.Windows.Media.Brushes.Transparent;
            ((Border)b.Parent).BorderBrush = selected ? Hex("#731FB58F") : System.Windows.Media.Brushes.Transparent;
            var stack = (StackPanel)b.Content;
            var label = (TextBlock)stack.Children[1];
            label.Foreground = B(selected ? "Text" : "Text2");
            label.FontWeight = selected ? FontWeights.SemiBold : FontWeights.Medium;
            PanelSymbols.SetTint((Viewbox)stack.Children[0], selected ? "Text" : "Text2");
        }
        // Подписи вкладок — на текущем языке (язык меняется без перезапуска).
        foreach (var (label, ru) in tabLabels.Values) label.Text = L.T(ru);
        sections.Children.Clear();
        content = sections;
        switch (section)
        {
            case Section.General: General(); break;
            case Section.Routes: Routes(); break;
            case Section.Network: Network(); break;
            case Section.More: More(); break;
            case Section.About: About(); break;
        }
        scroll.ScrollToTop();
        RefreshApplyBar();
    }

    bool lastNeedsApply;
    public void RefreshApplyBar()
    {
        var needs = m.NeedsApply;
        if (needs == lastNeedsApply && applyBar.Content != null == needs) return;
        lastNeedsApply = needs;
        if (!needs) { applyBar.Content = null; return; }
        var apply = Btn(m.IsConnected ? "Принять и переподключить" : "Принять изменения", async () => { await m.ApplySettings(); Rebuild(); }, primary: true);
        var discard = Btn("Отменить", () => { m.DiscardDraft(); Rebuild(); });
        discard.Margin = new Thickness(8, 0, 0, 0);
        var row = Row(T("Есть непринятые изменения", 12, color: "Busy"), apply, discard);
        row.Margin = new Thickness(18, 8, 18, 0);
        applyBar.Content = row;
    }

    // MARK: помощники полей

    void Edit(Action<AppSettings> change)
    {
        var before = m.Settings.Copy();
        change(m.Settings);
        m.SettingsEdited(before);
    }

    void Title(string text) => heading.Text = L.T(text);
    void Head(string text)
    {
        var header = T(text, 14, FontWeights.SemiBold);
        header.Margin = new Thickness(10, 22, 0, 8);
        sections.Children.Add(header);
        content = new StackPanel();
        sections.Children.Add(Card(content, 10, new Thickness(12, 6, 12, 8)));
    }
    void Note(string text) { var h = Hint(text); h.Margin = new Thickness(0, 4, 0, 4); content.Children.Add(h); }

    void Toggle(string title, Func<AppSettings, bool> get, Action<AppSettings, bool> set, string? hint = null)
    {
        var label = hint == null ? (UIElement)T(title, 14, wrap: true) : V(2, T(title, 14, wrap: true), Hint(hint));
        var cb = new CheckBox { Content = label, IsChecked = get(m.Settings), Margin = new Thickness(0, 6, 0, 6) };
        cb.Click += (_, _) =>
        {
            Edit(s => set(s, cb.IsChecked == true));
            if (section == Section.Network) { var offset = scroll.VerticalOffset; Rebuild(); scroll.ScrollToVerticalOffset(offset); }
        };
        content.Children.Add(cb);
    }

    void Segments<TE>(string? title, (TE value, string label)[] items, Func<AppSettings, TE> get, Action<AppSettings, TE> set, string? hint = null) where TE : notnull
    {
        var picker = Dropdown(items, get(m.Settings), v => Edit(s => set(s, v)));
        if (title == null) content.Children.Add(picker);
        else { picker.MaxWidth = 200; content.Children.Add(WithMargin(Row(T(title, 14, wrap: true), picker), 0,4,0,4)); }
        if (hint != null) Note(hint);
    }

    void Field(string title, Func<AppSettings, string> get, Action<AppSettings, string> set, string? hint = null)
    {
        content.Children.Add(WithMargin(T(title, 13, color: "Text2"), 0, 8, 0, 4));
        var box = new TextBox { Text = get(m.Settings) };
        box.TextChanged += (_, _) => Edit(s => set(s, box.Text.Trim()));
        content.Children.Add(box);
        if (hint != null) Note(hint);
    }

    void IntField(string title, Func<AppSettings, int> get, Action<AppSettings, int> set, int min, int max, string? hint = null)
    {
        content.Children.Add(WithMargin(T(title, 13, color: "Text2"), 0, 8, 0, 4));
        var box = new TextBox { Text = get(m.Settings).ToString(), Width = 120, HorizontalAlignment = HorizontalAlignment.Left };
        var err = T(L.F("От %@ до %@", min, max), 11, color: "Bad");
        err.Visibility = Visibility.Collapsed;
        box.TextChanged += (_, _) =>
        {
            var ok = int.TryParse(box.Text, out var v) && v >= min && v <= max;
            err.Visibility = ok ? Visibility.Collapsed : Visibility.Visible;
            if (ok) Edit(s => set(s, v));
        };
        content.Children.Add(H(10, box, err));
        if (hint != null) Note(hint);
    }

    void ListField(string title, Func<AppSettings, List<string>> get, Action<AppSettings, List<string>> set, string? hint = null)
    {
        content.Children.Add(WithMargin(T(title, 13, color: "Text2"), 0, 8, 0, 4));
        var box = new TextBox
        {
            Text = string.Join(Environment.NewLine, get(m.Settings)), AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
            Height = 76, VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        box.TextChanged += (_, _) => Edit(s => set(s, box.Text.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList()));
        content.Children.Add(box);
        if (hint != null) Note(hint);
    }

    void Buttons(params Button[] buttons)
    {
        var w = new WrapPanel { Margin = new Thickness(0, 8, 0, 0) };
        foreach (var b in buttons) { b.Margin = new Thickness(0, 0, 8, 8); w.Children.Add(b); }
        content.Children.Add(w);
    }

    static T2 WithMargin<T2>(T2 e, double l, double t, double r, double b) where T2 : FrameworkElement { e.Margin = new Thickness(l, t, r, b); return e; }

    // MARK: разделы

    void General()
    {
        Title("Основные");
        Head("Язык интерфейса");
        var langs = new List<(string, string)> { ("", L.T("Как в системе")) };
        langs.AddRange(L.Languages.Select(l => (l.Code, l.Native)));
        content.Children.Add(Dropdown(langs.ToArray(), UiPrefs.Current.Language ?? "", v => L.Set(v.Length == 0 ? null : v)));
        if (!L.TablesPresent) Note("Таблиц переводов пока нет в папке l10n — интерфейс останется на русском.");
        Head("Подключение");
        Segments("Режим", [(ConnectionMode.Tun, "Весь трафик Windows"), (ConnectionMode.Proxy, "Системный прокси")], s => s.Mode, (s, v) => s.Mode = v,
            "Весь трафик — через виртуальный адаптер (wintun), работает для всех программ. Прокси — только для программ, которые учитывают системный прокси (браузеры).");

        Toggle("Аварийная блокировка при потере туннеля", s => s.KillSwitch, (s, v) => s.KillSwitch = v,
            "Только в режиме «Весь трафик». Служба блокирует интернет (фильтр Windows Filtering Platform), обнаружив падение туннеля, и снимает блокировку, когда он поднимется. Короткий промежуток до обнаружения аварии не защищён. Если сама служба упала, блокировка тоже снимается.");
        Toggle("Запасной сервер", s => s.Failover, (s, v) => s.Failover = v, "При ручном выборе сервера служба перейдёт на самый быстрый, если выбранный перестал отвечать.");
        Head("Автопереключение");
        IntField("Проверять связь каждые, с", s => s.ProbeIntervalSec, (s, v) => s.ProbeIntervalSec = v, 10, 300);
        IntField("Неудачных проверок подряд до переключения", s => s.HealthFailLimit, (s, v) => s.HealthFailLimit = v, 1, 10);

        Head("Клик по стране");
        Segments("К какому серверу подключаться", [(CountryPick.Fastest, "Самый быстрый"), (CountryPick.LastUsed, "Последний"), (CountryPick.First, "Первый"), (CountryPick.Random, "Случайный")],
            s => s.CountryPick, (s, v) => s.CountryPick = v);
        Toggle("В стране — только избранные серверы, если они есть", s => s.CountryPreferFavorites, (s, v) => s.CountryPreferFavorites = v);

        Head("Запуск");
        Toggle("Запускать вместе с Windows (в трее)", s => s.LaunchAtLogin, (s, v) => s.LaunchAtLogin = v);
        Toggle("Подключаться при запуске", s => s.ConnectOnLaunch, (s, v) => s.ConnectOnLaunch = v);
        Note("Служба сама восстанавливает подключение после перезагрузки компьютера, даже без окна.");

        Head("Уведомления");
        Toggle("Показывать уведомления", s => s.Notifications, (s, v) => s.Notifications = v);

    }

    void Routes()
    {
        Title("Маршруты");
        Head("Маршрутизация");
        Segments("Что пускать через VPN", [(RoutingMode.Rule, "По правилам"), (RoutingMode.Global, "Всё"), (RoutingMode.Direct, "Ничего (напрямую)")],
            s => s.RoutingMode, (s, v) => s.RoutingMode = v);
        // Сайты какой страны пускать напрямую (банки, госуслуги, местные сервисы) — выбор, как и раньше «российские».
        var regionItems = new List<(string, string)> { ("", "Нет — всё по остальным правилам") };
        regionItems.AddRange(HomeRegions.All.Select(r => (r.Code, Loc.Country(r.Code.ToUpperInvariant()))));
        Segments("Сайты страны — напрямую", regionItems.ToArray(), s => s.RussiaDirect ? s.DirectCountry : "",
            (s, v) => { s.RussiaDirect = v.Length > 0; if (v.Length > 0) s.DirectCountry = v; },
            "Банки, госуслуги и местные сервисы выбранной страны идут без VPN. Россия, Китай, Иран — готовые списки сайтов и IP-адреса страны; Мьянма — банки и доменная зона; Турция, ОАЭ — только доменная зона (.tr, .ae).");
        Toggle("Блокировать рекламу и трекеры", s => s.BlockAds, (s, v) => s.BlockAds = v);

        GeoSettings();

        Head("Профиль маршрутов");
        var items = new List<(string, string)> { ("", "Без профиля") };
        items.AddRange(m.Profiles.Select(p => (p.Id.ToString(), p.Name + (p.FromSubscription != null ? " · от провайдера" : ""))));
        content.Children.Add(Dropdown(items.ToArray(), m.Settings.ActiveProfileID?.ToString() ?? "", v => Edit(s =>
        {
            var p = m.Profiles.FirstOrDefault(x => x.Id.ToString() == v);
            s.ActiveProfileID = p?.Id;
            if (p?.GeoipURL is { } g1 && p.GeositeURL is { } g2) { s.GeoipURL = g1; s.GeositeURL = g2; }
        })));
        if (m.Profiles.FirstOrDefault(x => x.Id == m.Settings.ActiveProfileID) is { } active)
            Buttons(Btn("Скопировать ссылку профиля", () => { Clipboard.SetText(RoutingProfiles.Link(active)); m.Message = "Ссылка профиля скопирована"; }),
                    Btn("Удалить профиль", () => { m.Profiles.Remove(active); Edit(s => s.ActiveProfileID = null); m.ScheduleSave(); Rebuild(); }));
        var profileLink = new TextBox { ToolTip = L.T("happ://routing/add/… или JSON профиля") };
        var import = Btn("Добавить", () =>
        {
            var text = profileLink.Text.Trim();
            var profile = RoutingProfiles.ParseLink(text) ?? RoutingProfiles.ParseJSON(text);
            if (profile == null) { m.Message = L.T("Профиль не распознан"); return; }
            m.AddProfile(profile);
            Edit(s => { s.ActiveProfileID = profile.Id;
                if (profile.GeoipURL != null) s.GeoipURL = profile.GeoipURL;
                if (profile.GeositeURL != null) s.GeositeURL = profile.GeositeURL; });
            Rebuild();
        });
        import.IsEnabled = false;
        profileLink.TextChanged += (_, _) => import.IsEnabled = !string.IsNullOrWhiteSpace(profileLink.Text);
        content.Children.Add(Hint("happ://routing/add/… или JSON профиля"));
        content.Children.Add(Row(profileLink, import));

        Head("Сайты");
        ListField("Напрямую", s => s.DirectDomains, (s, v) => s.DirectDomains = v, "По одному в строке: example.com (с поддоменами), geosite:…, full:…, regexp:…");
        ListField("Всегда через VPN", s => s.ProxyDomains, (s, v) => s.ProxyDomains = v);
        ListField("Блокировать", s => s.BlockDomains, (s, v) => s.BlockDomains = v);

        Head("IP-адреса");
        ListField("Напрямую", s => s.DirectIPs, (s, v) => s.DirectIPs = v, "1.2.3.4, 10.0.0.0/8, geoip:…");
        ListField("Всегда через VPN", s => s.ProxyIPs, (s, v) => s.ProxyIPs = v);
        ListField("Блокировать", s => s.BlockIPs, (s, v) => s.BlockIPs = v);
        ListField("Мимо туннеля целиком", s => s.ExcludedRoutes, (s, v) => s.ExcludedRoutes = v, "Адреса, которые не попадают даже в xray. Только IP и подсети.");

        Head("Приложения");
        Segments(null, [(AppsMode.Exclude, "Выбранные — мимо VPN"), (AppsMode.Include, "Только выбранные — через VPN")], s => s.AppsMode, (s, v) => s.AppsMode = v);
        ListField("Мимо VPN", s => s.DirectApps, (s, v) => s.DirectApps = v, "Имена программ: Telegram.exe, steam.exe. Работает в режиме «Весь трафик Windows».");
        ListField("Только через VPN", s => s.IncludeApps, (s, v) => s.IncludeApps = v);

        Head("Дополнительно");
        Segments("Стратегия доменов", [("AsIs", "AsIs"), ("IPIfNonMatch", "IPIfNonMatch"), ("IPOnDemand", "IPOnDemand")], s => s.DomainStrategy, (s, v) => s.DomainStrategy = v);
    }

    void Network()
    {
        Title("Сеть и туннель");
        Head("DNS");
        Field("Через VPN", s => s.RemoteDNS, (s, v) => s.RemoteDNS = v, "1.1.1.1 (будет DoH), https://…/dns-query, tls://…");
        Field("Для сайтов страны (напрямую)", s => s.DirectDNS, (s, v) => s.DirectDNS = v, "77.88.8.8 — для России; при другой стране вместо него берётся DNS провайдера.");
        Toggle("IPv6", s => s.Ipv6, (s, v) => s.Ipv6 = v);


        Head("Обход блокировок");
        Toggle("Фрагментация TLS", s => s.Fragment, (s, v) => s.Fragment = v, "Режет приветствие TLS на части — помогает, когда сервер блокируют по SNI.");
        if (m.Settings.Fragment)
        {
        Field("Пакеты", s => s.FragmentPackets, (s, v) => s.FragmentPackets = v);
        Field("Длина", s => s.FragmentLength, (s, v) => s.FragmentLength = v);
        Field("Интервал, мс", s => s.FragmentInterval, (s, v) => s.FragmentInterval = v);
        }
        Toggle("Шумовые пакеты", s => s.Noises, (s, v) => s.Noises = v);
        Toggle("Mux", s => s.Mux, (s, v) => s.Mux = v, "Несколько соединений в одном. Не для XHTTP и Vision.");
        if (m.Settings.Mux) IntField("Потоков", s => s.MuxConcurrency, (s, v) => s.MuxConcurrency = v, 1, 128);

        Toggle("Определять сайты по трафику (sniffing)", s => s.Sniffing, (s, v) => s.Sniffing = v);

        Head("Локальная сеть");
        Toggle("Раздавать VPN другим устройствам", s => s.AllowLAN, (s, v) => s.AllowLAN = v, "Другие устройства подключаются к этому компьютеру как к прокси. Разрешите порты в брандмауэре Windows.");
        if (m.Settings.AllowLAN)
        {
        IntField("SOCKS-порт", s => s.LanSocksPort, (s, v) => s.LanSocksPort = v, 1025, 65000);
        IntField("HTTP-порт", s => s.LanHttpPort, (s, v) => s.LanHttpPort = v, 1025, 65000);
        Field("Логин", s => s.LanUser, (s, v) => s.LanUser = v);
        content.Children.Add(T("Пароль", 13, color: "Text2"));
        var password = new PasswordBox { Password = m.Settings.LanPassword, Padding = new Thickness(6) };
        password.PasswordChanged += (_, _) => Edit(s => s.LanPassword = password.Password);
        content.Children.Add(password);
        if (m.Applied.AllowLAN)
        {
            foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up &&
                    n.NetworkInterfaceType is System.Net.NetworkInformation.NetworkInterfaceType.Wireless80211 or System.Net.NetworkInformation.NetworkInterfaceType.Ethernet && n.Name != Paths.TunName))
                foreach (var ip in nic.GetIPProperties().UnicastAddresses.Where(a => a.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork))
                    Note($"HTTP {ip.Address}:{m.Applied.LanHttpPort} · SOCKS5 {ip.Address}:{m.Applied.LanSocksPort}");
        }

        }

        Head("Проверка серверов");
        Segments("Способ", [(PingType.Url, "Настоящий запрос"), (PingType.Tcp, "TCP-соединение")], s => s.PingType, (s, v) => s.PingType = v);
        Field("Адрес проверки", s => s.TestURL, (s, v) => s.TestURL = v);
        IntField("Таймаут, с", s => s.TestTimeout, (s, v) => s.TestTimeout = v, 2, 30);
        Toggle("Проверять при запуске", s => s.PingOnLaunch, (s, v) => s.PingOnLaunch = v);
        Toggle("Проверять после обновления подписки", s => s.PingAfterUpdate, (s, v) => s.PingAfterUpdate = v);
        Segments("Сортировка серверов", [(ServerSort.Ping, "По задержке"), (ServerSort.Name, "По имени"), (ServerSort.None, "Как в подписке")], s => s.Sort, (s, v) => s.Sort = v);

    }

    void ToolRow(string title, string symbol, string color, Action open)
    {
        var badge = new Border { Width = 27, Height = 27, Background = B(color), CornerRadius = new CornerRadius(6),
            Child = PanelSymbols.Draw(symbol, 16, "Text") };
        var button = Flat(Row(H(10, badge, T(title, 14)), PanelSymbols.Draw("macwindow", 14)), open, title, new Thickness(4,6,4,6));
        System.Windows.Automation.AutomationProperties.SetName(button, L.T(title));
        content.Children.Add(button);
    }

    void More()
    {
        Title("Дополнительно");
        Head("Окна");
        ToolRow("Соединения", "point.3.connected.trianglepath.dotted", "On", () => InfoWindows.ShowConnections(owner));
        ToolRow("Статистика", "chart.bar.fill", "Busy", () => InfoWindows.ShowStats(owner));
        ToolRow("Журнал", "doc.text.fill", "Brand", () => InfoWindows.ShowLog(owner));
        Note("Открываются отдельным небольшим окном.");
        Head("Как Tutun запрашивает подписки");
        Toggle("Отправлять ID устройства", s => s.SendHWID, (s, v) => s.SendHWID = v, "Нужно панелям с лимитом устройств (Remnawave и др.).");
        content.Children.Add(Row(T("ID устройства", 13, color: "Text2"), T(m.Applied.Hwid, 13)));
        Field("User-Agent", s => s.UserAgent, (s, v) => s.UserAgent = v, "Пусто — " + SubscriptionFetcher.DefaultUserAgent);
        IntField("Таймаут загрузки, с", s => s.SubTimeout, (s, v) => s.SubTimeout = v, 5, 120);
        Toggle("Пропускать одинаковые серверы", s => s.IgnoreDuplicates, (s, v) => s.IgnoreDuplicates = v);
        Toggle("Разрешить подписки по http", s => s.AllowHttpSubscriptions, (s, v) => s.AllowHttpSubscriptions = v,
            "Небезопасно: по http ключи серверов видны провайдеру и любому в сети, список могут подменить. Включайте только для своей панели без https. ID устройства по http не отправляется.");
        Toggle("Обновлять подписки при запуске", s => s.UpdateSubsOnLaunch, (s, v) => s.UpdateSubsOnLaunch = v);

        IntField("Предупреждать об окончании за, дней", s => s.ExpiryWarnDays, (s, v) => s.ExpiryWarnDays = v, 0, 30);

        Head("Серверы");
        Buttons(
            Btn("Убрать нерабочие", () => m.RemoveDead()),
            Btn($"Вернуть скрытые ({m.Hidden.Count})", () => { m.UnhideAll(); Rebuild(); }),
            Btn("Скопировать все ссылки", () => { Clipboard.SetText(m.ExportAllLinks()); m.Message = "Ссылки скопированы"; }));

        Head("Анимации");
        content.Children.Add(Dropdown([("", "Как в Windows"), ("on", "Всегда"), ("off", "Никогда")],
            UiPrefs.Current.Animations switch { true => "on", false => "off", _ => "" },
            v => { UiPrefs.Current.Animations = v switch { "on" => true, "off" => false, _ => null }; UiPrefs.Current.Save(); }));
        Note(System.Windows.SystemParameters.ClientAreaAnimation ? "В Windows анимации включены." : "В Windows анимации выключены (Параметры → Специальные возможности → Визуальные эффекты).");
        Head("Резервная копия");
        Buttons(
            Btn("Сохранить…", () =>
            {
                var dlg = new SaveFileDialog { Filter = "Резервная копия Tutun|*.json", FileName = $"tutun-backup-{DateTime.Now:yyyy-MM-dd}.json" };
                if (dlg.ShowDialog(owner) == true) { m.ExportBackup(dlg.FileName); m.Message = "Сохранено. В файле ключи серверов — храните как пароль."; }
            }),
            Btn("Восстановить…", () =>
            {
                var dlg = new OpenFileDialog { Filter = "Резервная копия Tutun (Windows или Mac app.json)|*.json" };
                if (dlg.ShowDialog(owner) != true) return;
                try { m.ImportBackup(dlg.FileName); Rebuild(); } catch (Exception e) { m.Message = "Не прочитать: " + e.Message; }
            }));
        Note("Подходит и app.json с мака: серверы, подписки и настройки переносятся, ID устройства остаётся этим.");

        Head("Управление ссылками");
        Note("tutun://connect, tutun://disconnect, tutun://toggle — можно вызывать из ярлыков и планировщика.");

    }

    void GeoSettings()
    {
        Head("Гео-базы");
        Toggle("Обновлять раз в неделю", s => s.GeoAutoUpdate, (s, v) => s.GeoAutoUpdate = v);
        Field("geoip.dat", s => s.GeoipURL, (s, v) => s.GeoipURL = v);
        Field("geosite.dat", s => s.GeositeURL, (s, v) => s.GeositeURL = v);
        geoButton = Btn("Обновить сейчас", () => _ = m.UpdateGeo());
        Buttons(geoButton);
        // The route panel is rebuilt when the tab changes.
        if (geoStatus.Parent is Panel old) old.Children.Clear();
        geoRing.Stroke = B("On");
        content.Children.Add(H(8, geoRing, geoStatus));
        RefreshGeoProgress();
    }

    void RefreshGeoProgress()
    {
        var progress = m.Status.GeoUpdate;
        if (geoButton != null) geoButton.IsEnabled = m.DaemonReachable && !m.DaemonOutdated && !m.GeoUpdating && (progress == null || progress.CompletedAt != null || progress.Error != null);
        var loading = progress?.Stage == "Загрузка";
        geoRing.Visibility = loading ? Visibility.Visible : Visibility.Collapsed;
        var fraction = progress?.Total is > 0 ? Math.Clamp((double)progress.Downloaded / progress.Total.Value, 0, 1) : .25;
        if (loading)
        {
            var angle = Math.Clamp(fraction, .001, .99999) * Math.PI * 2;
            var end = new Point(14 + 11 * Math.Sin(angle), 14 - 11 * Math.Cos(angle));
            var figure = new System.Windows.Media.PathFigure { StartPoint = new Point(14, 3) };
            figure.Segments.Add(new System.Windows.Media.ArcSegment(end, new Size(11, 11), 0, fraction > .5, System.Windows.Media.SweepDirection.Clockwise, true));
            geoRing.Data = new System.Windows.Media.PathGeometry([figure]);
        }
        var spin = Animations && loading && progress?.Total is not > 0;
        if (spin != geoSpinning)
        {
            geoSpinning = spin;
            var rotation = new System.Windows.Media.RotateTransform();
            geoRing.RenderTransform = rotation;
            if (spin) rotation.BeginAnimation(System.Windows.Media.RotateTransform.AngleProperty,
                new System.Windows.Media.Animation.DoubleAnimation(0, 360, TimeSpan.FromSeconds(1)) { RepeatBehavior = System.Windows.Media.Animation.RepeatBehavior.Forever });
        }
        if (progress == null)
        {
            geoStatus.Text = m.Applied.GeoLastUpdate is { } updated ? $"Обновлены {updated.LocalDateTime:g}" : "";
            return;
        }
        var size = progress.Stage == "Загрузка" ? $" · {progress.Downloaded / 1048576.0:F1} МБ" : "";
        var percent = progress.Total is > 0 && loading ? $" · {fraction:P0}" : "";
        var completed = progress.CompletedAt is { } at ? $" · {at.LocalDateTime:g}" : "";
        geoStatus.Text = $"{progress.File} {L.T(progress.Stage)}{size}{percent}{completed} {progress.Error}".Trim();
    }

    StackPanel? serviceDetails;
    string serviceSignature = "";

    void RefreshService()
    {
        if (section != Section.About || serviceDetails == null || !View.IsVisible) return;
        var installed = m.ServiceInstalled;
        var signature = $"{installed}|{m.DaemonReachable}|{m.Status.Version}|{m.Status.Restarts}|{m.Busy}|{m.ServiceStage}";
        if (serviceSignature == signature) return;
        serviceSignature = signature;
        serviceDetails.Children.Clear();
        var state = m.DaemonReachable ? L.F("работает, версия %@", m.Status.Version) + (m.DaemonOutdated ? L.T(" — устарела") : "")
            : L.T(installed ? "установлена, не отвечает" : "не установлена");
        serviceDetails.Children.Add(Row(T("Состояние", 14), T(state, 13, color: "Text2")));
        serviceDetails.Children.Add(Row(T("Перезапусков ядра", 14), T(m.Status.Restarts.ToString(), 13, color: "Text2")));
        if (m.ServiceStage is { } stage) { serviceDetails.Children.Add(T(stage, 13, color: "On")); return; }
        var actions = new WrapPanel { IsEnabled = !m.Busy, Margin = new Thickness(0,8,0,4) };
        actions.Children.Add(Btn(installed ? "Переустановить службу" : "Установить службу", () => _ = m.InstallService()));
        if (installed)
        {
            var remove = Btn("Удалить службу", () =>
            {
                if (MessageBox.Show(owner, L.T("Удалить службу Tutun? VPN отключится, подключаться будет нельзя до новой установки."), "Tutun", MessageBoxButton.YesNo) == MessageBoxResult.Yes)
                    _ = m.InstallService(install: false);
            });
            remove.Foreground = B("Bad"); remove.Margin = new Thickness(6,0,0,0);
            actions.Children.Add(remove);
        }
        serviceDetails.Children.Add(actions);
    }

    void About()
    {
        Title("О программе");
        var u = UpdateModel.Shared;
        var prefs = UiPrefs.Current;
        var icon = new System.Windows.Controls.Image { Source = new System.Windows.Media.Imaging.BitmapImage(new Uri("pack://application:,,,/Assets/tutun256.png")), Width = 64, Height = 64 };
        var head = H(14, icon, V(2, T("Tutun", 22, FontWeights.Bold), T(L.F("Версия %@", Updater.CurrentVersion), 13, color: "Text2"),
                                 T("VPN-клиент на xray и sing-box", 12, color: "Text3")));
        sections.Children.Add(Card(head, 9, new Thickness(14,12,14,12)));

        Head("Обновления");
        content.Children.Add(T(u.StatusText, 14, FontWeights.SemiBold, u.Error != null ? "Bad" : (u.Available != null || u.CheckedOnce ? "On" : "Text"), wrap: true));
        if (u.Available is { } a)
        {
            if (a.Notes.Trim().Length > 0)
            {
                content.Children.Add(WithMargin(T("Что нового", 13, color: "Text2"), 0, 10, 0, 4));
                content.Children.Add(Card(T(a.Notes.Trim(), 12, wrap: true), 10));
            }
            var install = Btn("Установить и перезапустить", () => _ = u.Install(), primary: true);
            install.IsEnabled = u.Installing == null;
            Buttons(install);
        }
        // Напоминание при каждом обновлении (требование): VPN держит служба.
        if (u.Available != null || u.Installing != null) Note(Updater.VpnStaysNote);
        var check = Btn("Проверить обновления", () => _ = u.Check(manual: true));
        check.IsEnabled = !u.Checking && u.Installing == null;
        check.HorizontalAlignment = HorizontalAlignment.Left;
        content.Children.Add(WithMargin(Row(check, T(prefs.UpdateLastCheck?.ToLocalTime().ToString("g", L.Culture) ?? "", 12, color: "Text2")), 0,9,0,5));

        var auto = new CheckBox { Content = T("Проверять автоматически", 14), IsChecked = prefs.UpdateAutoCheck, Margin = new Thickness(0, 6, 0, 6) };
        auto.Click += (_, _) => { prefs.UpdateAutoCheck = auto.IsChecked == true; prefs.Save(); Rebuild(); };
        content.Children.Add(auto);
        if (prefs.UpdateAutoCheck)
        {
            content.Children.Add(Row(T("Как часто", 14), Dropdown([(1, "Раз в день"), (7, "Раз в неделю"), (14, "Раз в 2 недели"), (30, "Раз в месяц")],
            prefs.UpdateIntervalDays, v => { prefs.UpdateIntervalDays = v; prefs.Save(); })));

        }

        Head("Служба");
        Buttons(Btn("Сохранить диагностический отчёт…", () =>
        {
            var dialog = new SaveFileDialog { FileName = "tutun-diagnostics.json", Filter = "JSON|*.json" };
            if (dialog.ShowDialog(owner) != true) return;
            var state = m.Status;
            var diagnostic = new { app = Updater.CurrentVersion, os = Environment.OSVersion.Version.ToString(),
                reachable = m.DaemonReachable, service = m.DaemonReachable ? state.Version : null,
                state.State, state.Mode, state.Healthy, state.EmergencyBlock, state.Restarts, state.LatencyMs,
                geoStage = state.GeoUpdate?.Stage, m.Applied.GeoLastUpdate };
            try { File.WriteAllText(dialog.FileName, Json.Serialize(diagnostic, pretty: true)); }
            catch (Exception e) { m.Message = e.Message; }
        }));
        serviceDetails = new StackPanel();
        content.Children.Add(serviceDetails);
        serviceSignature = "";
        RefreshService();

        Head("Проект");
        Buttons(Btn("Страница на GitHub", () => SystemIntegration.OpenUrl(Updater.RepoPage)), Btn("Все версии", () => SystemIntegration.OpenUrl(Updater.ReleasesPage)));
        Note("Обновления приходят из выпусков GitHub. Если вышла новая версия службы, приложение предложит её обновить.");
        Note("Tutun проверяет SHA-256 архива, подпись Ed25519 и подписанный манифест выпуска.");

    }
}
