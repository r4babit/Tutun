using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using Microsoft.Win32;
using Tutun.Core;

namespace Tutun.App;

public sealed record IPInfo(string Ip, string Country, string CountryCode, string City);

/// Связь с Windows в сеансе пользователя.
public static class SystemIntegration
{
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    /// Автозапуск окна при входе в Windows (свёрнутым в трей).
    public static void SetLaunchAtLogin(bool on)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey);
        if (on) k.SetValue("Tutun", $"\"{Environment.ProcessPath}\" --tray");
        else k.DeleteValue("Tutun", false);
    }

    /// Ссылки tutun:// (подключить/отключить/импорт) открываются этим приложением.
    public static void RegisterUrlScheme()
    {
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(@"Software\Classes\tutun");
            k.SetValue("", "URL:Tutun");
            k.SetValue("URL Protocol", "");
            using var cmd = k.CreateSubKey(@"shell\open\command");
            cmd.SetValue("", $"\"{Environment.ProcessPath}\" \"%1\"");
        }
        catch { }
    }

    /// Служба поменяла прокси в реестре — просим WinINet (браузеры, системные программы) перечитать настройки.
    public static void RefreshWinInet()
    {
        InternetSetOption(IntPtr.Zero, 39 /* INTERNET_OPTION_SETTINGS_CHANGED */, IntPtr.Zero, 0);
        InternetSetOption(IntPtr.Zero, 37 /* INTERNET_OPTION_REFRESH */, IntPtr.Zero, 0);
    }

    [DllImport("wininet.dll", SetLastError = true)]
    static extern bool InternetSetOption(IntPtr hInternet, int option, IntPtr buffer, int len);

    /// Тёмная полоса заголовка окна (Windows 10 20H1+ / 11).
    public static void DarkTitleBar(IntPtr hwnd)
    {
        int on = 1;
        DwmSetWindowAttribute(hwnd, 20, ref on, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    /// Другие VPN-клиенты, которые могут конфликтовать с TUN.
    static readonly (string Process, string Name)[] Known =
    [
        ("Happ", "Happ"), ("v2rayN", "v2rayN"), ("Hiddify", "Hiddify"), ("clash-verge", "Clash Verge"), ("FlClash", "FlClash"),
        ("Outline", "Outline"), ("AmneziaVPN", "AmneziaVPN"), ("NordVPN", "NordVPN"), ("ExpressVPN", "ExpressVPN"),
        ("Surfshark", "Surfshark"), ("ProtonVPN", "Proton VPN"), ("nekoray", "NekoRay"), ("Throne", "Throne"), ("INCY", "INCY"),
    ];

    public static List<string> Conflicts()
    {
        var names = Process.GetProcesses().Select(p => { try { return p.ProcessName; } catch { return ""; } }).ToHashSet(StringComparer.OrdinalIgnoreCase);
        return Known.Where(k => names.Contains(k.Process)).Select(k => k.Name).ToList();
    }

    /// Внешний IP и страна (через VPN — по socks-порту службы).
    public static async Task<IPInfo?> FetchIP(int? socksPort)
    {
        try
        {
            using var http = TestHarness.Client(socksPort, TimeSpan.FromSeconds(10));
            var text = await http.GetStringAsync("https://ipwho.is/?lang=ru");
            var o = Json.ParseObject(text);
            if (o == null || o["success"]?.GetValue<bool>() == false) return null;
            return new IPInfo(o.Str("ip") ?? "", o.Str("country") ?? "", o.Str("country_code") ?? "", o.Str("city") ?? "");
        }
        catch { return null; }
    }

    public static void OpenUrl(string url)
    {
        if (!ConnectionValidation.HttpURL(url)) return;
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
    }

    public static void OpenFile(string path)
    {
        try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); } catch { }
    }
}
