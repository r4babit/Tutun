using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using Tutun.Core;
using static Tutun.App.UI;

namespace Tutun.App;

/// «Добавить»: ссылка подписки, ссылки серверов, файл (список, WireGuard .conf, JSON, профиль tutun.profile).
public sealed class AddPanel
{
    readonly MainWindow owner;
    readonly AppModel m = AppModel.Shared;
    readonly StackPanel root = new() { Margin = new Thickness(18, 16, 18, 16) };
    readonly StackPanel subs = new();
    readonly TextBox input = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 138, FontFamily = new System.Windows.Media.FontFamily("Cascadia Mono, Consolas"), VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    Button? addButton;
    string subsSignature = "";
    public FrameworkElement View { get; }

    public AddPanel(MainWindow owner)
    {
        this.owner = owner;
        View = Scroll(root);
        input.TextChanged += (_, _) => { if (addButton != null) addButton.IsEnabled = !string.IsNullOrWhiteSpace(input.Text); };
    }

    public void Rebuild(bool prefill = false)
    {
        if (subs.Parent is Panel oldPanel) oldPanel.Children.Remove(subs);
        root.Children.Clear();
        if (prefill && string.IsNullOrWhiteSpace(input.Text))
        {
            try { var value = Clipboard.GetText().Trim(); if (value.Length <= 16384 && value.Contains("://")) input.Text = value; }
            catch (System.Runtime.InteropServices.COMException) { }
        }
        root.Children.Add(T("Добавить", 20, FontWeights.Bold));
        root.Children.Add(WithTop(Hint("Ссылка подписки (https://…), ссылки серверов (vless, vmess, trojan, ss, hysteria2, tuic, wireguard, socks), happ://add, tutun://, JSON или конфиг WireGuard. Можно перетащить файл в окно."), 6));
        input.Margin = new Thickness(0, 12, 0, 0);
        root.Children.Add(input);
        var add = Btn("Добавить", async () =>
        {
            var t = input.Text.Trim();
            if (t.Length == 0) { m.Message = "Вставьте ссылку"; return; }
            int serverCount = m.Servers.Count, subscriptionCount = m.Subscriptions.Count, profileCount = m.Profiles.Count;
            root.IsEnabled = false;
            try
            {
                await m.ImportText(t);
                if (m.Servers.Count > serverCount || m.Subscriptions.Count > subscriptionCount && m.Subscriptions.Last().LastError == null || m.Profiles.Count > profileCount)
                {
                    input.Clear();
                    if (m.Panel == SidePanel.Add) owner.SetPanel(SidePanel.Servers);
                }
            }
            finally { root.IsEnabled = true; }
        }, primary: true);
        var paste = Btn("Из буфера", () =>
        {
            var t = Clipboard.ContainsText() ? Clipboard.GetText() : "";
            if (t.Trim().Length == 0) { m.Message = "В буфере нет текста"; return; }
            input.Text = t; input.Focus();
        });
        var file = Btn("Файл", async () =>
        {
            var dlg = new OpenFileDialog { Filter = "Ссылки, конфиги, профили, QR-картинки|*.txt;*.conf;*.json;*.png;*.jpg;*.jpeg;*.bmp|Все файлы|*.*" };
            if (dlg.ShowDialog(owner) != true) return;
            if (QR.ImageExtensions.Contains(Path.GetExtension(dlg.FileName).ToLowerInvariant()))
            { try { await m.ImportQR(QR.FromFile(dlg.FileName)); } catch (Exception e) { m.Message = e.Message; } return; }
            var bytes = await File.ReadAllBytesAsync(dlg.FileName);
            if (bytes.Length > 16 << 20) { m.Message = "Файл слишком большой"; return; }
            await m.ImportText(System.Text.Encoding.UTF8.GetString(bytes));
        });

        var qrScreen = Btn("QR с экрана", async () =>
        {
            // Окно прячем, чтобы оно не закрывало QR-код на экране.
            owner.Hide();
            await Task.Delay(350);
            List<string> codes;
            try { codes = QR.FromScreen(); } finally { owner.Show(); owner.Activate(); }
            await m.ImportQR(codes);
        }, tip: "Найдёт QR-код подписки или сервера на любом экране");
        var qrFile = Btn("QR-картинка", async () =>
        {
            var dlg = new OpenFileDialog { Filter = "Картинки|*.png;*.jpg;*.jpeg;*.bmp;*.gif|Все файлы|*.*" };
            if (dlg.ShowDialog(owner) != true) return;
            try { await m.ImportQR(QR.FromFile(dlg.FileName)); } catch (Exception e) { m.Message = "Не прочитать картинку: " + e.Message; }
        });
        var manual = Btn("Сервер вручную…", () => ServerEditor.Show(owner, null));
        var sources = new System.Windows.Controls.Primitives.UniformGrid { Columns = 2 };
        foreach (var (source, symbol) in new[] { (paste, "doc.on.clipboard"), (qrScreen, "qrcode.viewfinder"), (qrFile, "photo"), (file, "doc") })
        {
            var label = source.Content.ToString()!;
            System.Windows.Automation.AutomationProperties.SetName(source, label);
            var text = T(label, 12); text.HorizontalAlignment = HorizontalAlignment.Center;
            source.Content = V(5, PanelSymbols.Draw(symbol, 21, "Text"), text);
            source.Height = 64;
            source.Margin = new Thickness(3);
            sources.Children.Add(source);
        }
        root.Children.Add(WithTop(sources, 10));
        addButton = add;
        add.IsEnabled = !string.IsNullOrWhiteSpace(input.Text);
        root.Children.Add(WithTop(new UniformGrid3(Btn("Отмена", () => owner.SetPanel(null)), Gap(add)), 8));
        // Keep Windows management commands available below the primary import workflow.
        var extra = new StackPanel();
        var disclosure = new Expander { Header = L.T("Дополнительно"), Content = extra, Foreground = B("Text2"), Margin = new Thickness(0,16,0,0) };
        root.Children.Add(disclosure);
        extra.Children.Add(WithTop(manual, 10));

        extra.Children.Add(Header("Подписки"));
        extra.Children.Add(subs);
        subsSignature = "";
        RefreshList();

        extra.Children.Add(Header("Общий профиль Tutun"));
        extra.Children.Add(Hint("Формат tutun.profile v1 — для переноса серверов и сетевых настроек между Windows, Mac и Android. Сетевые настройки попадают в черновик: их нужно принять."));
        var imp = Btn("Импорт профиля…", () =>
        {
            var dlg = new OpenFileDialog { Filter = "Профиль Tutun|*.json|Все файлы|*.*" };
            if (dlg.ShowDialog(owner) == true) m.ImportProfile(File.ReadAllBytes(dlg.FileName));
        });
        var exp = Btn("Экспорт профиля…", () =>
        {
            var dlg = new SaveFileDialog { Filter = "Профиль Tutun|*.json", FileName = "profile.tutun.json" };
            if (dlg.ShowDialog(owner) != true) return;
            try { File.WriteAllText(dlg.FileName, m.ExportProfile()); m.Message = "Профиль сохранён. В нём ключи серверов — храните как пароль."; }
            catch (Exception e) { m.Message = "Не сохранить: " + e.Message; }
        });
        var row = new UniformGrid3(imp, Gap(exp));
        row.Margin = new Thickness(0, 8, 0, 0);
        extra.Children.Add(row);
    }

    static FrameworkElement Gap(FrameworkElement e) { e.Margin = new Thickness(8, 0, 0, 0); return e; }
    static FrameworkElement WithTop(FrameworkElement e, double t) { e.Margin = new Thickness(0, t, 0, 0); return e; }

    public void RefreshList()
    {
        var sig = string.Join("|", m.Subscriptions.Select(s => $"{s.Id}{s.Name}{s.LastUpdate}{s.LastError}{s.Enabled}")) + m.UpdatingSubs;
        if (sig == subsSignature) return;
        subsSignature = sig;
        subs.Children.Clear();
        if (m.Subscriptions.Count == 0) { subs.Children.Add(Hint("Подписок нет")); return; }
        foreach (var s in m.Subscriptions)
        {
            var count = m.Servers.Count(x => x.SubscriptionID == s.Id);
            var sub = s.LastError != null ? T(s.LastError, 11, color: "Bad", wrap: true)
                : T($"{Format.ServersWord(count)} · обновлено {(s.LastUpdate is { } lu ? lu.LocalDateTime.ToString("dd.MM HH:mm") : "—")}", 11, color: "Text3");
            var info = V(2, T(s.Name, 14, FontWeights.SemiBold), sub);
            var upd = IconButton("arrow.clockwise", () => _ = m.Update(s.Id), "Обновить", 13);
            upd.IsEnabled = !m.UpdatingSubs;
            var more = IconButton("info.circle", () => SubscriptionInfo.Show(owner, s.Id), "Подробнее", 14);
            var card = Card(Row(info, upd, more), 10, new Thickness(12, 8, 6, 8));
            card.Margin = new Thickness(0, 0, 0, 6);
            subs.Children.Add(card);
        }
        var all = Btn("Обновить все", () => _ = m.UpdateAll());
        all.IsEnabled = !m.UpdatingSubs;
        all.HorizontalAlignment = HorizontalAlignment.Left;
        subs.Children.Add(all);
    }
}
