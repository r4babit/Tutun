using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Windows;
using Tutun.Core;
using WinForms = System.Windows.Forms;

namespace Tutun.App;

public partial class App : Application
{
    Mutex? single;
    WinForms.NotifyIcon? tray;
    MainWindow? window;
    TrayPanel? trayPanel;
    static string ActivationPipe => "tutun.app." + WindowsIdentity.GetCurrent().User!.Value;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var args = e.Args;
        if (args.Length == 4 && args[0] == "--apply-update")
        {
            Shutdown(Updater.Apply(args[1], args[2], int.TryParse(args[3], out var pid) ? pid : 0));
            return;
        }
        if (args.Length > 0 && args[0] is "--install-service" or "--uninstall-service")
        {
            Shutdown(Installer.Run(args));
            return;
        }

        // Одна копия на пользователя: вторая передаёт свои аргументы (ссылку tutun://) первой.
        single = new Mutex(true, "Local\\Tutun.App", out var first);
        if (!first)
        {
            ForwardToRunning(args);
            Shutdown();
            return;
        }

        DispatcherUnhandledException += (_, ex) =>
        {
            AppModel.Shared.Message = "Ошибка: " + ex.Exception.Message;
            ex.Handled = true;
        };

        L.Load();
        SystemIntegration.RegisterUrlScheme();
        var m = AppModel.Shared;
        m.Notify += (title, text) =>
        {
            if (tray == null) return;
            tray.ShowBalloonTip(4000, L.T(title), string.IsNullOrEmpty(text) ? " " : L.T(text), WinForms.ToolTipIcon.None);
        };
        m.Changed += UpdateTray;
        m.Start();
        CreateTray();
        _ = ListenForActivation();

        window = new MainWindow();
        var trayOnly = args.Contains("--tray");
        if (!trayOnly) window.Show();
        foreach (var a in args.Where(a => a.Contains("://"))) _ = m.HandleUrl(a);
    }

    void CreateTray()
    {
        tray = new WinForms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(GetResourceStream(new Uri("pack://application:,,,/Assets/tutun.ico")).Stream),
            Text = "Tutun",
            Visible = true,
        };
        var menu = new WinForms.ContextMenuStrip();
        var toggle = new WinForms.ToolStripMenuItem(L.T("Подключить"), null, async (_, _) => await AppModel.Shared.Toggle()) { Name = "toggle" };
        menu.Items.Add(toggle);
        menu.Items.Add(L.T("Самый быстрый"), null, async (_, _) => await AppModel.Shared.SelectFastest());
        menu.Items.Add(new WinForms.ToolStripSeparator());
        menu.Items.Add(L.T("Открыть Tutun"), null, (_, _) => ShowWindow());
        menu.Items.Add(L.T("Выход"), null, (_, _) => Quit());
        menu.Opening += (_, _) => toggle.Text = L.T(AppModel.Shared.IsConnected ? "Отключить" : "Подключить");
        tray.ContextMenuStrip = menu;
        tray.MouseClick += (_, ev) => { if (ev.Button != WinForms.MouseButtons.Left) return;
            if (trayPanel is { IsVisible: true }) { trayPanel.Close(); return; }
            window ??= new MainWindow();
            trayPanel = new TrayPanel(window, ShowWindow, Quit);
            trayPanel.Closed += (_, _) => trayPanel = null;
            trayPanel.Show();
            trayPanel?.Activate(); };
        UpdateTray();
    }

    string lastTrayText = "";
    void UpdateTray()
    {
        if (tray == null) return;
        var m = AppModel.Shared;
        var text = "Tutun — " + StatusText.Title(m.Status, m.DaemonReachable) + (m.IsConnected && m.CurrentCountryName is { } c ? ": " + c : "");
        if (text.Length > 63) text = text[..63];
        if (text != lastTrayText) { tray.Text = text; lastTrayText = text; }
    }

    public void ShowWindow()
    {
        window ??= new MainWindow();
        window.Show();
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
    }

    public void Quit()
    {
        try { AppModel.Shared.SaveNow(); } catch { }
        if (tray != null) { tray.Visible = false; tray.Dispose(); }
        Shutdown();
    }

    async Task ListenForActivation()
    {
        while (true)
        {
            try
            {
                await using var pipe = new NamedPipeServerStream(ActivationPipe, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                await pipe.WaitForConnectionAsync();
                var line = Encoding.UTF8.GetString(await Ipc.ReadLineAsync(pipe, new CancellationTokenSource(5000).Token));
                ShowWindow();
                foreach (var a in line.Split('\t').Where(a => a.Contains("://"))) await AppModel.Shared.HandleUrl(a);
            }
            catch { await Task.Delay(500); }
        }
    }

    static void ForwardToRunning(string[] args)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", ActivationPipe, PipeDirection.Out);
            pipe.Connect(2000);
            var data = Encoding.UTF8.GetBytes(string.Join('\t', args) + "\n");
            pipe.Write(data);
            pipe.Flush();
        }
        catch { }
    }
}
