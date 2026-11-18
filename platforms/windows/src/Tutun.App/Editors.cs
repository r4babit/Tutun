using System.Windows;
using System.Windows.Controls;
using Tutun.Core;
using static Tutun.App.UI;

namespace Tutun.App;

static class Dialogs
{
    public static Window Make(Window owner, string title, double width)
    {
        var w = new Window
        {
            Title = L.T(title), Owner = owner, Width = width, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = B("Bg"), ShowInTaskbar = false,
        };
        w.SourceInitialized += (_, _) => SystemIntegration.DarkTitleBar(new System.Windows.Interop.WindowInteropHelper(w).Handle);
        return w;
    }

    public static FrameworkElement Label(string text) { var t = T(text, 13, color: "Text2"); t.Margin = new Thickness(0, 10, 0, 4); return t; }
}

/// Редактор сервера: имя и ссылка (или JSON outbound для серверов без ссылки).
public static class ServerEditor
{
    public static void Show(Window owner, Server? original)
    {
        var m = AppModel.Shared;
        var w = Dialogs.Make(owner, original == null ? "Новый сервер" : "Изменить сервер", 560);
        var name = new TextBox { Text = original == null ? "" : m.DisplayName(original) };
        var useLink = original?.RawLink != null || original == null;
        var link = new TextBox { Text = original?.RawLink ?? "", TextWrapping = TextWrapping.Wrap, AcceptsReturn = false, Height = 70, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var json = new TextBox
        {
            Text = original == null ? "" : Json.ToJSON(original.Outbound, pretty: true), AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
            Height = 240, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), FontSize = 12,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        var p = new StackPanel { Margin = new Thickness(18) };
        p.Children.Add(T(w.Title, 18, FontWeights.Bold));
        if (original?.SubscriptionID != null) p.Children.Add(Hint("Сервер из подписки: после сохранения появится его копия среди добавленных вручную, а подписка останется как есть."));
        p.Children.Add(Dialogs.Label("Имя")); p.Children.Add(name);
        var linkBlock = V(0, Dialogs.Label("Ссылка (vless://, vmess://, trojan://, ss://, hysteria2://, tuic://, wireguard://, socks://)"), link);
        var jsonBlock = V(0, Dialogs.Label("Outbound в JSON (xray, или sing-box для TUIC/Hysteria2)"), json);
        var mode = Dropdown([(true, "Ссылкой"), (false, "JSON")], useLink, v =>
        {
            linkBlock.Visibility = v ? Visibility.Visible : Visibility.Collapsed;
            jsonBlock.Visibility = v ? Visibility.Collapsed : Visibility.Visible;
            useLink = v;
        });
        p.Children.Add(Dialogs.Label("Как задать")); p.Children.Add(mode);
        linkBlock.Visibility = useLink ? Visibility.Visible : Visibility.Collapsed;
        jsonBlock.Visibility = useLink ? Visibility.Collapsed : Visibility.Visible;
        p.Children.Add(linkBlock); p.Children.Add(jsonBlock);
        var err = T("", 12, color: "Bad", wrap: true); err.Margin = new Thickness(0, 8, 0, 0);
        p.Children.Add(err);
        var save = Btn("Сохранить", () =>
        {
            try
            {
                m.SaveEdited(original, useLink ? link.Text.Trim() : null, useLink ? null : json.Text, name.Text);
                w.Close();
            }
            catch (Exception e) { err.Text = e.Message; }
        }, primary: true);
        var cancel = Btn("Отмена", () => w.Close());
        var row = Row(new Border(), cancel, new Border { Width = 8 }, save);
        row.Margin = new Thickness(0, 14, 0, 0);
        p.Children.Add(row);
        w.Content = p;
        w.ShowDialog();
    }
}

/// Окно «i» у подписки: трафик, срок, объявление, свой интервал, скрытая ссылка, QR, поддержка, удаление; «Отмена/Сохранить».
public static class SubscriptionInfo
{
    public static void Show(Window owner, Guid id)
    {
        var m = AppModel.Shared;
        if (m.Subscriptions.FirstOrDefault(s => s.Id == id) is not { } s) return;
        var w = Dialogs.Make(owner, s.Name, 460);
        var p = new StackPanel { Margin = new Thickness(18) };
        p.Children.Add(T(s.Name, 18, FontWeights.Bold));
        void Line(string k, string v) { var r = Row(T(k, 13, color: "Text2"), T(v, 13, FontWeights.SemiBold)); r.Margin = new Thickness(0, 3, 0, 3); p.Children.Add(r); }
        p.Children.Add(new Border { Height = 8 });
        var used = s.Upload + s.Download;
        Line("Трафик", s.Total > 0 ? $"{Format.Bytes(used)} из {Format.Bytes(s.Total)}" : Format.Bytes(used));
        Line("Действует до", s.Expire is { } e ? e.LocalDateTime.ToString("dd.MM.yyyy") : "без срока");
        Line("Серверов", m.Servers.Count(x => x.SubscriptionID == s.Id).ToString());
        Line("Обновлена", s.LastUpdate is { } lu ? lu.LocalDateTime.ToString("dd.MM.yyyy HH:mm") : "—");
        if (s.LastError is { } err) { var t = T(err, 12, color: "Bad", wrap: true); t.Margin = new Thickness(0, 8, 0, 0); p.Children.Add(t); }
        if (!string.IsNullOrWhiteSpace(s.Announce)) { var c = Card(T(s.Announce, 13, wrap: true), 10); c.Margin = new Thickness(0, 10, 0, 0); p.Children.Add(c); }

        // Правки — в копии; применяются кнопкой «Сохранить».
        var name = new TextBox { Text = s.Name };
        p.Children.Add(Dialogs.Label("Имя")); p.Children.Add(name);
        var hours = s.UpdateIntervalHours;
        p.Children.Add(Dialogs.Label("Обновлять"));
        (int, string)[] intervals = [(1, "Каждый час"), (3, "Каждые 3 часа"), (6, "Каждые 6 часов"), (12, "Каждые 12 часов"), (24, "Раз в день"), (72, "Раз в 3 дня"), (168, "Раз в неделю")];
        if (!intervals.Any(i => i.Item1 == hours)) intervals = [.. intervals, (hours, $"Каждые {hours} ч")];
        p.Children.Add(Dropdown(intervals, hours, v => hours = v));
        var enabled = new CheckBox { Content = T("Использовать серверы подписки", 13), IsChecked = s.Enabled, Margin = new Thickness(0, 12, 0, 0) };
        p.Children.Add(enabled);

        // Ссылка скрыта: в ней ключ подписки.
        p.Children.Add(Dialogs.Label("Ссылка подписки"));
        var url = T(Mask(s.Url), 12, color: "Text3", wrap: true);
        var shown = false;
        var toggle = Btn("Показать", () => { });
        toggle.Click += (_, _) => { shown = !shown; url.Text = shown ? s.Url : Mask(s.Url); toggle.Content = shown ? "Скрыть" : "Показать"; };
        p.Children.Add(url);

        var buttons = new WrapPanel { Margin = new Thickness(0, 10, 0, 0) };
        void Add(Button b) { b.Margin = new Thickness(0, 0, 8, 8); buttons.Children.Add(b); }
        Add(toggle);
        Add(Btn("Скопировать", () => Clipboard.SetText(s.Url)));
        Add(Btn("QR-код", () => QR.Show(w, s.Name, s.Url)));
        Add(Btn("Обновить сейчас", () => { _ = m.Update(s.Id); w.Close(); }));
        if (s.SupportURL is { } sup && ConnectionValidation.HttpURL(sup)) Add(Btn("Поддержка", () => SystemIntegration.OpenUrl(sup)));
        if (s.WebPageURL is { } web && ConnectionValidation.HttpURL(web)) Add(Btn("Кабинет", () => SystemIntegration.OpenUrl(web)));
        var del = Btn("Удалить", () =>
        {
            if (MessageBox.Show(w, $"Удалить подписку «{s.Name}» и её серверы?", "Tutun", MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes)
            { m.RemoveSubscription(s.Id); w.Close(); }
        });
        del.Foreground = B("Bad");
        Add(del);
        p.Children.Add(buttons);

        var save = Btn("Сохранить", () =>
        {
            if (name.Text.Trim().Length > 0) s.Name = name.Text.Trim();
            s.UpdateIntervalHours = hours;
            s.Enabled = enabled.IsChecked == true;
            m.ScheduleSave(); m.SaveNow();
            m.NotifyChanged();
            w.Close();
        }, primary: true);
        var row = Row(new Border(), Btn("Отмена", () => w.Close()), new Border { Width = 8 }, save);
        row.Margin = new Thickness(0, 8, 0, 0);
        p.Children.Add(row);
        w.Content = p;
        w.ShowDialog();
    }

    static string Mask(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var u)) return "••••••";
        return $"{u.Scheme}://{u.Host}/••••••";
    }
}
