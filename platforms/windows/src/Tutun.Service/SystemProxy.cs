using System.Text;
using Microsoft.Win32;
using Tutun.Core;

namespace Tutun.Service;

/// Системный прокси пользователя-владельца (HKU\&lt;SID&gt;\…\Internet Settings).
/// Перед включением прежние значения сохраняются целиком в run\system-proxy.json и возвращаются при отключении
/// и после перезапуска службы. Окно приложения затем просит WinINet перечитать настройки в сеансе пользователя.
public sealed class SystemProxy(string ownerSid)
{
    const string KeyPath = @"\Software\Microsoft\Windows\CurrentVersion\Internet Settings";
    static string BackupPath => Path.Combine(Paths.RunDir, "system-proxy.json");
    static readonly string[] Values = ["ProxyEnable", "ProxyServer", "ProxyOverride", "AutoConfigURL", "AutoDetect"];
    const string Bypass = "localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>";

    public int Generation { get; private set; }

    sealed class Backup
    {
        public Dictionary<string, string?> Strings { get; set; } = new();
        public Dictionary<string, int?> Dwords { get; set; } = new();
        public string? ConnectionBlob { get; set; }
    }

    RegistryKey OpenKey()
    {
        return Registry.Users.OpenSubKey(ownerSid + KeyPath, writable: true)
               ?? throw new InvalidOperationException("Профиль пользователя не загружен: войдите в Windows под владельцем Tutun");
    }

    public void Enable()
    {
        using var key = OpenKey();
        if (!File.Exists(BackupPath))
        {
            var b = new Backup();
            foreach (var v in Values)
            {
                var o = key.GetValue(v);
                if (o is int i) b.Dwords[v] = i; else b.Strings[v] = o as string;
            }
            using (var conn = key.OpenSubKey("Connections"))
                if (conn?.GetValue("DefaultConnectionSettings") is byte[] blob) b.ConnectionBlob = Convert.ToBase64String(blob);
            File.WriteAllText(BackupPath, Json.Serialize(b));
        }
        var server = $"127.0.0.1:{Paths.HttpPort}";
        key.SetValue("ProxyEnable", 1, RegistryValueKind.DWord);
        key.SetValue("ProxyServer", server, RegistryValueKind.String);
        key.SetValue("ProxyOverride", Bypass, RegistryValueKind.String);
        key.DeleteValue("AutoConfigURL", false);
        using (var conn = key.CreateSubKey("Connections"))
        {
            var old = conn.GetValue("DefaultConnectionSettings") as byte[];
            conn.SetValue("DefaultConnectionSettings", BuildBlob(old, flags: 0x03, server, Bypass, ""), RegistryValueKind.Binary);
        }
        Generation++;
    }

    /// Вернуть то, что было до подключения. Без сохранённой копии ничего не трогаем.
    public void Restore()
    {
        if (!File.Exists(BackupPath)) return;
        var b = Json.Deserialize<Backup>(File.ReadAllText(BackupPath)) ?? new Backup();
        using (var key = OpenKey())
        {
            foreach (var (k, v) in b.Dwords) { if (v is int i) key.SetValue(k, i, RegistryValueKind.DWord); else key.DeleteValue(k, false); }
            foreach (var (k, v) in b.Strings) { if (v != null) key.SetValue(k, v, RegistryValueKind.String); else key.DeleteValue(k, false); }
            using var conn = key.CreateSubKey("Connections");
            var current = conn.GetValue("DefaultConnectionSettings") as byte[];
            if (b.ConnectionBlob != null)
            {
                var orig = Convert.FromBase64String(b.ConnectionBlob);
                // Счётчик изменений должен расти, иначе WinINet может проигнорировать старое значение.
                if (orig.Length >= 8 && current is { Length: >= 8 })
                    BitConverter.TryWriteBytes(orig.AsSpan(4, 4), BitConverter.ToInt32(current, 4) + 1);
                conn.SetValue("DefaultConnectionSettings", orig, RegistryValueKind.Binary);
            }
            else if (current != null)
            {
                conn.SetValue("DefaultConnectionSettings", BuildBlob(current, flags: 0x01, "", "", ""), RegistryValueKind.Binary);
            }
        }
        File.Delete(BackupPath);
        Generation++;
    }

    /// DefaultConnectionSettings: версия, счётчик, флаги (1 — напрямую, 2 — прокси, 4 — PAC, 8 — автоопределение), строки.
    static byte[] BuildBlob(byte[]? old, int flags, string proxy, string bypass, string pac)
    {
        var ms = new MemoryStream();
        var w = new BinaryWriter(ms);
        int version = old is { Length: >= 4 } ? BitConverter.ToInt32(old, 0) : 0x46;
        int counter = old is { Length: >= 8 } ? BitConverter.ToInt32(old, 4) + 1 : 1;
        w.Write(version); w.Write(counter); w.Write(flags);
        foreach (var s in new[] { proxy, bypass, pac })
        {
            var bytes = Encoding.ASCII.GetBytes(s);
            w.Write(bytes.Length); w.Write(bytes);
        }
        w.Write(new byte[32]);
        return ms.ToArray();
    }
}
