using Tutun.Core;

namespace Tutun.App;

/// Настройки окна, которые не входят в AppSettings (как UserDefaults на маке): язык и обновления.
/// Применяются сразу, без «Принять изменения». Файл: %APPDATA%\Tutun\ui.json.
public sealed class UiPrefs
{
    /// Код языка («ru», «en», …) или null — как в системе.
    public string? Language { get; set; }
    /// Анимации интерфейса: null — как в Windows («Показывать анимацию»), true/false — всегда/никогда.
    public bool? Animations { get; set; }
    public int UpdateIntervalDays { get; set; } = 1;
    public bool UpdateAutoCheck { get; set; } = true;
    public DateTimeOffset? UpdateLastCheck { get; set; }
    /// Версия, о которой уже уведомили (уведомляем один раз).
    public string? UpdateNotified { get; set; }
    public bool FavoritesCollapsed { get; set; }
    public string ManualListMode { get; set; } = "countries";
    public string ManualListSort { get; set; } = "name";
    public int HighestReleaseSequence { get; set; }

    static string FilePath => Path.Combine(Paths.UserDir, "ui.json");
    public static UiPrefs Current { get; private set; } = Load();

    static UiPrefs Load()
    {
        try { if (File.Exists(FilePath)) return Json.Deserialize<UiPrefs>(File.ReadAllText(FilePath)) ?? new(); }
        catch { }
        return new UiPrefs();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Paths.UserDir);
            File.WriteAllText(FilePath, Json.Serialize(this, pretty: true));
        }
        catch { }
    }
}
