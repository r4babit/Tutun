namespace Tutun.Core;

/// Пути и порты Windows-версии.
public static class Paths
{
    /// Папка установки: служба, приложение и ядра лежат рядом (Program Files\Tutun).
    /// Служба живёт в подпапке service (её обновляет только кнопка «Обновить службу»), ядра — общие, в bin рядом с окном.
    public static string InstallDir
    {
        get
        {
            var dir = AppContext.BaseDirectory.TrimEnd('\\');
            return Path.GetFileName(dir).Equals("service", StringComparison.OrdinalIgnoreCase) ? Path.GetDirectoryName(dir)! : dir;
        }
    }
    public static string AppCores(string root) => Directory.Exists(Path.Combine(root, "cores")) ? Path.Combine(root, "cores") : Path.Combine(root, "bin");
    public static string BinDir => Directory.Exists(Path.Combine(AppContext.BaseDirectory, "bin")) &&
        Path.GetFileName(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar)).Equals("service", StringComparison.OrdinalIgnoreCase)
        ? Path.Combine(AppContext.BaseDirectory, "bin") : AppCores(InstallDir);
    public static string Xray => Path.Combine(BinDir, "xray.exe");
    public static string SingBox => Path.Combine(BinDir, "sing-box.exe");

    /// Данные службы: доступ только SYSTEM и администраторам.
    public static string DataDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "Tutun");
    public static string RunDir => Path.Combine(DataDir, "run");
    public static string DaemonState => Path.Combine(DataDir, "state.json");
    public static string OwnerFile => Path.Combine(DataDir, "owner.sid");
    public static string Log => Path.Combine(DataDir, "tutun.log");
    public static string GeoDir => Path.Combine(DataDir, "geo");

    /// Настройки пользователя: %APPDATA%\Tutun\app.json.
    public static string UserDir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Tutun");
    public static string Store => Path.Combine(UserDir, "app.json");

    public const string PipeName = "tutun.service";
    public const string ServiceName = "TutunService";
    public const string TunName = "tutun";

    // Внутренние порты (только 127.0.0.1). Не 10808/10809, как на маке: их на Windows держат Happ и v2rayN.
    public const int SocksPort = 17808;
    public const int HttpPort = 17809;
    public const int ApiPort = 17085;
    public const int ClashPort = 17095;
    public const int HelperBasePort = 20000;
    public const int ProbeBasePort = 21000;
    public const int TestBasePort = 31000;
    public const int TestHelperBase = 33000;
}
