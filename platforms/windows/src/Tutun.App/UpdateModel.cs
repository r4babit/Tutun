namespace Tutun.App;

/// Состояние проверки обновлений для окна, трея и раздела «О Tutun».
public sealed class UpdateModel
{
    public static UpdateModel Shared { get; } = new();

    public UpdateInfo? Available { get; private set; }
    public bool Checking { get; private set; }
    public string? Installing { get; private set; }   // этап установки
    public string? Error { get; private set; }
    public bool CheckedOnce { get; private set; }
    public event Action? Changed;

    UpdateModel()
    {
        var t = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromMinutes(10) };
        t.Tick += async (_, _) => await CheckIfDue();
        t.Start();
    }

    public string StatusText => Installing != null ? "Загружаю и устанавливаю… " + Installing
        : Checking ? "Проверяю…"
        : Error != null ? "Ошибка: " + Error
        : Available?.Revoked == true ? "Установленная версия отозвана. " + L.F("Доступна версия %@", Available.Version)
        : Available != null ? L.F("Доступна версия %@", Available.Version)
        : CheckedOnce || UiPrefs.Current.UpdateLastCheck != null ? "У вас последняя версия"
        : "Ещё не проверялось";

    public async Task CheckIfDue()
    {
        var p = UiPrefs.Current;
        if (!p.UpdateAutoCheck) return;
        if (p.UpdateLastCheck is { } last && (DateTimeOffset.Now - last).TotalDays < Math.Max(1, p.UpdateIntervalDays)) return;
        await Check(manual: false);
    }

    public async Task Check(bool manual)
    {
        if (Checking || Installing != null) return;
        Checking = true; Error = null; Changed?.Invoke();
        try
        {
            Available = await Updater.CheckAsync();
            CheckedOnce = true;
            UiPrefs.Current.UpdateLastCheck = DateTimeOffset.Now;
            if (Available != null && UiPrefs.Current.UpdateNotified != Available.Version)
            {
                UiPrefs.Current.UpdateNotified = Available.Version;
                AppModel.Shared.RaiseNotify(L.F("Доступно обновление Tutun %@", Available.Version),
                    "VPN не отключится во время обновления. Установить — в «Настройки → О Tutun»");
            }
            UiPrefs.Current.Save();
        }
        catch (Exception e) { Available = null; if (manual) Error = e.Message; }
        finally { Checking = false; Changed?.Invoke(); }
    }

    public async Task Install()
    {
        if (Available is not { } u || Installing != null) return;
        Installing = "";
        Error = null; Changed?.Invoke();
        var err = await Updater.InstallAsync(u, new Progress<string>(s => { Installing = s; Changed?.Invoke(); }));
        Installing = null;
        if (err != null) { Error = err; Changed?.Invoke(); return; }
        ((App)System.Windows.Application.Current).Quit();
    }
}
