using System.Diagnostics;
using System.IO.Compression;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Tutun.Core;

namespace Tutun.App;

public sealed record UpdateInfo(string Version, string Notes, string PageUrl, string ZipUrl, string? ShaUrl, string SignatureUrl, bool Revoked);

/// Обновления из выпусков GitHub — та же схема, что на маке.
/// Файлы Windows в выпуске: Tutun-Windows-x64.zip и Tutun-Windows-x64.zip.sha256.
public static class Updater
{
    public const string Repo = "r4babit/Tutun";
    public const string RepoPage = "https://github.com/" + Repo;
    public const string ReleasesPage = RepoPage + "/releases";
    const string Api = "https://api.github.com/repos/" + Repo + "/releases/latest";
    const string ZipName = "Tutun-Windows-x64.zip";
    public const string VpnStaysNote = "VPN не отключится: подключение держит служба, пока обновляется приложение.";

    public static string CurrentVersion
    {
        get
        {
            var v = typeof(Updater).Assembly.GetName().Version ?? new Version(0, 0, 0);
            return $"{v.Major}.{v.Minor}.{v.Build}";
        }
    }

    /// «1.0.10» > «1.0.9»; «v» в начале убирается; недостающие части = 0.
    public static int Compare(string a, string b)
    {
        static int[] Parts(string s) => s.Trim().TrimStart('v', 'V').Split('.').Select(p => int.TryParse(new string(p.TakeWhile(char.IsDigit).ToArray()), out var n) ? n : 0).ToArray();
        var x = Parts(a); var y = Parts(b);
        for (int i = 0; i < Math.Max(x.Length, y.Length); i++)
        {
            var d = (i < x.Length ? x[i] : 0).CompareTo(i < y.Length ? y[i] : 0);
            if (d != 0) return d;
        }
        return 0;
    }

    static HttpClient Http(TimeSpan timeout)
    {
        var h = new HttpClient { Timeout = timeout };
        h.DefaultRequestHeaders.UserAgent.ParseAdd($"Tutun/{CurrentVersion}");
        return h;
    }

    /// null — новее нет (в том числе: выпусков ещё нет, или в выпуске нет файла для Windows).
    public static async Task<UpdateInfo?> CheckAsync()
    {
        using var http = Http(TimeSpan.FromSeconds(20));
        using var req = new HttpRequestMessage(HttpMethod.Get, Api);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        using var resp = await http.SendAsync(req);
        if (resp.StatusCode == System.Net.HttpStatusCode.NotFound) return null;
        resp.EnsureSuccessStatusCode();
        var o = Json.ParseObject(await resp.Content.ReadAsStringAsync()) ?? throw new InvalidDataException("пустой ответ GitHub");
        var tag = (o.Str("tag_name") ?? "").TrimStart('v', 'V');
        if (tag.Length == 0 || Compare(tag, CurrentVersion) <= 0) return null;
        string? Asset(string name) => (o.Arr("assets") ?? []).OfType<System.Text.Json.Nodes.JsonObject>()
            .FirstOrDefault(a => a.Str("name") == name)?.Str("browser_download_url");
        var zip = Asset(ZipName);
        if (zip == null) return null;   // выпуск только для других систем
        var manifestUrl = Asset("Tutun-release.json");
        var manifestSig = Asset("Tutun-release.json.sig");
        if (manifestUrl == null || manifestSig == null || Asset(ZipName + ".sig") is not { } archiveSig)
            throw new InvalidDataException("В выпуске отсутствует подписанный манифест или подпись архива");
        var data = await http.GetByteArrayAsync(manifestUrl);
        VerifyReleaseSignature(data, await http.GetStringAsync(manifestSig));
        var manifest = System.Text.Json.Nodes.JsonNode.Parse(data)?.AsObject() ?? throw new InvalidDataException("Неверный манифест");
        var sequence = manifest["sequence"]?.GetValue<int>() ?? 0;
        if (manifest.Str("version") != tag || sequence < UiPrefs.Current.HighestReleaseSequence)
            throw new InvalidDataException("Манифест устарел или версия не совпадает");
        bool Revoked(string version) => manifest["minimumVersion"] is { } min && Compare(version, min.ToString()) < 0
            || (manifest.Arr("blocked") ?? []).Any(v => v != null && Compare(version, v.ToString()) == 0);
        if (Revoked(tag)) throw new InvalidDataException("Предлагаемая версия отозвана");
        UiPrefs.Current.HighestReleaseSequence = sequence;
        UiPrefs.Current.Save();
        return new UpdateInfo(tag, o.Str("body") ?? "", o.Str("html_url") ?? ReleasesPage, zip, Asset(ZipName + ".sha256"), archiveSig, Revoked(CurrentVersion));
    }

    static void VerifyReleaseSignature(byte[] data, string signature)
    {
        var publicKey = Convert.FromBase64String("jnLRMeUWS4AYxicPiEtfhkaWTwL0Iu1dCcJuJst3dj0=");
        var sig = Convert.FromBase64String(signature.Trim());
        if (sig.Length != 64 || !Org.BouncyCastle.Math.EC.Rfc8032.Ed25519.Verify(sig, 0, publicKey, 0, data, 0, data.Length))
            throw new InvalidDataException("Подпись Ed25519 не прошла проверку");
    }

    // MARK: установка

    /// Подписан ли файл действительной подписью Authenticode; сертификат подписи.
    public static X509Certificate2? Signer(string path)
    {
        if (!Verify(path)) return null;
        try { return new X509Certificate2(X509Certificate.CreateFromSignedFile(path)); } catch { return null; }
    }

    /// Скачать, проверить и передать замену отдельному процессу. Возвращает текст ошибки или null (приложение закроется).
    public static async Task<string?> InstallAsync(UpdateInfo u, IProgress<string> progress)
    {
        // Решение пользователя (08.11.2026, все платформы): обновляться и без сертификата.
        // Установленная сборка подписана — новая обязана быть того же издателя. Без подписи защищают
        // контрольная сумма из выпуска (от битого файла, но не от взлома аккаунта GitHub), проверка версии и целостность подписи, если она есть.
        var mine = Signer(Environment.ProcessPath!);
        if (u.ShaUrl == null) return "В выпуске нет контрольной суммы — установка отменена.";
        var dir = Directory.CreateTempSubdirectory("tutun-update-").FullName;
        try
        {
            using var http = Http(TimeSpan.FromMinutes(10));
            progress.Report("Загружаю…");
            var zipPath = Path.Combine(dir, ZipName);
            var archive = await http.GetByteArrayAsync(u.ZipUrl);
            VerifyReleaseSignature(archive, await http.GetStringAsync(u.SignatureUrl));
            await File.WriteAllBytesAsync(zipPath, archive);
            var expected = (await http.GetStringAsync(u.ShaUrl)).Trim().Split(' ', '\t', '\n')[0].ToLowerInvariant();
            await using (var fs = File.OpenRead(zipPath))
            {
                var actual = Convert.ToHexStringLower(await SHA256.HashDataAsync(fs));
                if (actual != expected) return "Контрольная сумма архива не совпала — установка отменена.";
            }
            progress.Report("Проверяю…");
            var staged = Path.Combine(dir, "Tutun");
            ZipFile.ExtractToDirectory(zipPath, staged);
            // Архив может содержать папку Tutun внутри.
            if (!File.Exists(Path.Combine(staged, "Tutun.exe")) && Directory.GetDirectories(staged).FirstOrDefault(d => File.Exists(Path.Combine(d, "Tutun.exe"))) is { } inner)
                staged = inner;
            var exe = Path.Combine(staged, "Tutun.exe");
            if (!File.Exists(exe) || !File.Exists(Path.Combine(staged, "Tutun.Service.exe")))
                return "В архиве нет Tutun — установка отменена.";
            var fv = FileVersionInfo.GetVersionInfo(exe);
            if (Compare($"{fv.FileMajorPart}.{fv.FileMinorPart}.{fv.FileBuildPart}", u.Version) != 0)
                return "Версия в архиве не совпадает с выпуском — установка отменена.";
            foreach (var f in new[] { exe, Path.Combine(staged, "Tutun.Service.exe") })
            {
                var trust = VerifyCode(f);
                if (trust != 0 && trust != TRUST_E_NOSIGNATURE) return "Подпись новой версии повреждена — установка отменена.";
                if (mine != null)
                {
                    var s = Signer(f);
                    if (s == null || s.Thumbprint != mine.Thumbprint) return "Подпись новой версии не совпадает с текущей — установка отменена.";
                }
            }
            progress.Report("Устанавливаю…");
            // Замену делает новая версия отдельным процессом с правами администратора после выхода этого окна.
            var psi = new ProcessStartInfo(exe)
            {
                UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden,
                Arguments = $"--apply-update \"{staged}\" \"{Path.GetDirectoryName(Environment.ProcessPath)}\" {Environment.ProcessId}",
            };
            try { Process.Start(psi); }
            catch (System.ComponentModel.Win32Exception) { return "Установка отменена: нужны права администратора."; }
            return null;
        }
        catch (Exception e) { return "Не удалось установить обновление: " + e.Message; }
    }

    /// Выполняется новой версией с правами администратора: ждёт выхода старого окна, заменяет файлы,
    /// при ошибке возвращает старые, запускает окно от имени пользователя. Службу не трогает:
    /// её файлы, занятые работающей службой, переименовываются, а сама служба обновляется кнопкой «Обновить службу».
    public static int Apply(string staged, string target, int oldPid)
    {
        try { Process.GetProcessById(oldPid).WaitForExit(30000); } catch { }
        var moved = new List<(string from, string to)>();
        var created = new List<string>();
        try
        {
            foreach (var src in Directory.GetFiles(staged, "*", SearchOption.AllDirectories))
            {
                var rel = Path.GetRelativePath(staged, src);
                // Папку службы обновляет только кнопка «Обновить службу».
                if (rel.StartsWith("service" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) continue;
                if (rel.StartsWith("bin" + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    rel = Path.Combine("cores", rel[4..]);
                var dst = Path.Combine(target, rel);
                Directory.CreateDirectory(Path.GetDirectoryName(dst)!);
                if (File.Exists(dst))
                {
                    var old = dst + ".old";
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(dst, old);   // переименование работает и для файлов, занятых службой
                    moved.Add((old, dst));
                }
                else created.Add(dst);
                File.Copy(src, dst);
            }
        }
        catch
        {
            foreach (var dst in created.AsEnumerable().Reverse()) { try { File.Delete(dst); } catch { } }
            foreach (var (old, dst) in moved.AsEnumerable().Reverse()) { try { File.Move(old, dst, true); } catch { } }
            Process.Start("explorer.exe", $"\"{Path.Combine(target, "Tutun.exe")}\"");
            return 1;
        }
        // Окно — от имени пользователя, не администратора.
        Process.Start("explorer.exe", $"\"{Path.Combine(target, "Tutun.exe")}\"");
        return 0;
    }

    const int TRUST_E_NOSIGNATURE = unchecked((int)0x800B0100);

    static bool Verify(string path) => VerifyCode(path) == 0;

    // WinVerifyTrust: 0 — подпись Authenticode действительна, TRUST_E_NOSIGNATURE — подписи нет, иное — повреждена/недоверена.
    static int VerifyCode(string path)
    {
        var file = new WINTRUST_FILE_INFO { cbStruct = (uint)Marshal.SizeOf<WINTRUST_FILE_INFO>(), pcwszFilePath = path };
        var pFile = Marshal.AllocHGlobal(Marshal.SizeOf(file));
        try
        {
            Marshal.StructureToPtr(file, pFile, false);
            var data = new WINTRUST_DATA
            {
                cbStruct = (uint)Marshal.SizeOf<WINTRUST_DATA>(), dwUIChoice = 2 /* WTD_UI_NONE */, fdwRevocationChecks = 0,
                dwUnionChoice = 1 /* WTD_CHOICE_FILE */, pFile = pFile, dwStateAction = 0, dwProvFlags = 0x10 /* WTD_SAFER_FLAG */,
            };
            var action = new Guid("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");   // WINTRUST_ACTION_GENERIC_VERIFY_V2
            return WinVerifyTrust(IntPtr.Zero, ref action, ref data);
        }
        catch { return -1; }
        finally { Marshal.FreeHGlobal(pFile); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WINTRUST_FILE_INFO { public uint cbStruct; public string pcwszFilePath; public IntPtr hFile; public IntPtr pgKnownSubject; }

    [StructLayout(LayoutKind.Sequential)]
    struct WINTRUST_DATA
    {
        public uint cbStruct; public IntPtr pPolicyCallbackData; public IntPtr pSIPClientData; public uint dwUIChoice;
        public uint fdwRevocationChecks; public uint dwUnionChoice; public IntPtr pFile; public uint dwStateAction;
        public IntPtr hWVTStateData; public IntPtr pwszURLReference; public uint dwProvFlags; public uint dwUIContext; public IntPtr pSignatureSettings;
    }

    [DllImport("wintrust.dll", CharSet = CharSet.Unicode)]
    static extern int WinVerifyTrust(IntPtr hwnd, ref Guid action, ref WINTRUST_DATA data);
}
