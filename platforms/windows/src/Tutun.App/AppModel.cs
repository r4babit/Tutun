using System.Security.Cryptography;
using System.Text;
using System.Windows.Threading;
using Tutun.Core;

namespace Tutun.App;

public sealed class DayStat { public long Up { get; set; } public long Down { get; set; } }

public enum SidePanel { Servers, Settings, Add }

/// Файл настроек пользователя: тот же состав полей, что app.json мака (резервные копии переносятся).
public sealed class Store
{
    public List<Server> Servers { get; set; } = new();
    public List<Subscription> Subscriptions { get; set; } = new();
    public List<RoutingProfile> Profiles { get; set; } = new();
    public AppSettings Settings { get; set; } = new();
    public Dictionary<string, DayStat> Days { get; set; } = new();
    public Dictionary<string, long> ServerUsage { get; set; } = new();
    public List<string> Hidden { get; set; } = new();
    public Dictionary<string, DateTimeOffset> LastExpiryWarn { get; set; } = new();
    public List<string> LastCandidateIDs { get; set; } = new();
    public Dictionary<string, int> Pings { get; set; } = new();
}

public sealed record Country(string Id, string Name, List<Server> Servers, int? BestPing);
public sealed record ServerGroup(string Id, string Title, int Count, List<Country> Countries, Guid? SubscriptionId);

/// Состояние окна: серверы, подписки, черновик и принятые настройки, связь со службой. Порт AppModel мака.
public sealed class AppModel
{
    public static AppModel Shared { get; } = new();

    public List<Server> Servers = new();
    public List<Subscription> Subscriptions = new();
    public List<RoutingProfile> Profiles = new();
    /// Черновик: поля настроек меняют только его.
    public AppSettings Settings = new();
    /// Принятые настройки: ими пользуются подключение и фоновые действия.
    public AppSettings Applied = new();
    public Dictionary<string, DayStat> Days = new();
    public Dictionary<string, long> ServerUsage = new();
    public HashSet<string> Hidden = new();
    Dictionary<string, DateTimeOffset> lastExpiryWarn = new();

    public DaemonStatus Status = new();
    public bool DaemonReachable;
    public Dictionary<string, int> Pings = new();     // мс; -1 — недоступен
    public Dictionary<string, double> Speeds = new(); // байт/с
    public bool Testing;
    public string? SpeedTesting;
    public bool Busy;
    public double SpeedUp, SpeedDown;
    public List<double> History = Enumerable.Repeat(0.0, 60).ToList();
    public bool UpdatingSubs;
    public IPInfo? IpVPN, IpDirect;
    public List<string> ConflictList = new();
    public SidePanel? Panel;
    public HashSet<string> CollapsedGroups = new();

    string? message;
    public string? Message { get => message; set { message = value; MessageChanged?.Invoke(); } }

    /// Что-то поменялось в списке/состоянии — перерисовать.
    public event Action? Changed;
    public event Action? MessageChanged;
    public event Action<string, string>? Notify;

    List<Server> lastCandidates = new();
    (DateTime t, long up, long down)? lastSample;
    string? lastActive;
    TunnelState lastState = TunnelState.Stopped;
    int lastProxyGeneration = -1;
    bool loaded;
    readonly DispatcherTimer saveTimer;
    readonly List<DispatcherTimer> timers = new();

    AppModel()
    {
        saveTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
        saveTimer.Tick += (_, _) => { saveTimer.Stop(); SaveNow(); };
    }

    public void Start()
    {
        Load();
        if (Settings.Hwid.Length == 0)
        {
            Settings.Hwid = Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(8));
            Applied.Hwid = Settings.Hwid;
        }
        loaded = true;
        SaveNow();
        _ = WatchService();
        Every(TimeSpan.FromSeconds(1), RefreshStatus);
        Every(TimeSpan.FromMinutes(10), Periodic);
        _ = Startup();
    }

    async Task WatchService()
    {
        while (true)
        {
            if (!DaemonReachable || Status.Version != DaemonStatus.DaemonVersion) { await Task.Delay(3000); continue; }
            try
            {
                var revision = Status.Revision;
                var change = await Call(new DaemonRequest { Cmd = DaemonCommand.WaitForChange, Revision = revision }, TimeSpan.FromSeconds(12));
                if (change.Revision != Status.Revision) await RefreshStatus();
            }
            catch { await Task.Delay(3000); }
        }
    }

    async Task Startup()
    {
        await RefreshStatus();
        ConflictList = SystemIntegration.Conflicts();
        if (Applied.UpdateSubsOnLaunch) await UpdateDueSubscriptions(force: true);
        if (Applied.PingOnLaunch) await PingAll();
        if (Applied.ConnectOnLaunch && !IsConnected && DaemonReachable) await Connect();
        await Periodic();
        await UpdateModel.Shared.CheckIfDue();
    }

    void Every(TimeSpan interval, Func<Task> action)
    {
        var running = false;
        var t = new DispatcherTimer { Interval = interval };
        t.Tick += async (_, _) => { if (running) return; running = true; try { await action(); } finally { running = false; } };
        t.Start();
        timers.Add(t);
    }

    void Raise() => Changed?.Invoke();
    public void RaiseNotify(string title, string text) => Notify?.Invoke(title, text);
    public void NotifyChanged() => Raise();

    // MARK: производные

    public bool IsConnected => Status.State is TunnelState.Running or TunnelState.Reconnecting or TunnelState.Starting;
    public bool ServiceInstalled => Installer.ServiceInstalled;
    public bool DaemonOutdated => DaemonReachable && Status.Version != DaemonStatus.DaemonVersion;
    public bool NeedsApply => !Settings.SameAs(Applied);

    public string DisplayName(Server s) => Settings.ServerRenames.TryGetValue(s.Id, out var n) ? n : s.Name;
    public string CleanName(Server s) => s.CleanName(DisplayName(s));

    public IEnumerable<Server> VisibleServers => Servers.Where(s => !Hidden.Contains(s.Id));

    public int PingValue(Server s) => Pings.TryGetValue(s.Id, out var p) ? (p < 0 ? int.MaxValue : p) : int.MaxValue - 1;
    bool Alive(Server s) => !Pings.TryGetValue(s.Id, out var p) || p >= 0;

    public List<Server> Sorted(IEnumerable<Server> list)
    {
        var l = list.ToList();
        return Settings.Sort switch
        {
            ServerSort.Ping => l.OrderByDescending(s => s.Favorite).ThenBy(PingValue).ThenBy(DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList(),
            ServerSort.Name => l.OrderByDescending(s => s.Favorite).ThenBy(DisplayName, StringComparer.CurrentCultureIgnoreCase).ToList(),
            _ => l.OrderByDescending(s => s.Favorite).ToList(),
        };
    }

    /// Серверы, которые можно отдавать ядру (не скрытые, из включённых подписок, допустимые).
    public List<Server> UsableServers
    {
        get
        {
            var disabled = Subscriptions.Where(s => !s.Enabled).Select(s => s.Id).ToHashSet();
            return VisibleServers.Where(s => LinkParser.RejectReason(s) == null && !(s.SubscriptionID is { } id && disabled.Contains(id))).ToList();
        }
    }

    public Server? SelectedServer => Servers.FirstOrDefault(s => s.Id == Settings.SelectedServerID);

    public string? ActiveServerName
    {
        get
        {
            if (Status.ActiveOutbound is { Length: > 1 } tag && int.TryParse(tag[1..], out var i) && i < lastCandidates.Count) return DisplayName(lastCandidates[i]);
            if (lastCandidates.Count == 1) return DisplayName(lastCandidates[0]);
            return null;
        }
    }

    /// Сервер, через который сейчас идёт VPN (или выбранный, если не подключено).
    public Server? CurrentServer
    {
        get
        {
            if (IsConnected && ActiveServerName is { } n && lastCandidates.FirstOrDefault(s => DisplayName(s) == n) is { } s) return s;
            if (!Settings.AutoSelect && Settings.SelectedCountry == null) return SelectedServer;
            return null;
        }
    }

    public int? CurrentLatency => CurrentServer is { } s && Pings.TryGetValue(s.Id, out var p) && p >= 0 ? p : (IsConnected ? Status.LatencyMs : null);

    public string? CurrentCountryName
    {
        get
        {
            if (CurrentServer?.CountryCode is { } code) return Loc.Country(code);
            if (!Settings.AutoSelect && Settings.SelectedCountry is { } c) return Loc.Country(c);
            if (IsConnected && IpVPN is { Country.Length: > 0 } ip) return ip.Country;
            return IsConnected ? Status.ServerLabel : null;
        }
    }

    public string? CurrentCountryCode
    {
        get
        {
            if (CurrentServer?.CountryCode is { } code) return code;
            if (!Settings.AutoSelect && Settings.SelectedCountry is { } c) return c;
            return IsConnected && IpVPN is { CountryCode.Length: > 0 } ip ? ip.CountryCode : null;
        }
    }

    public string SelectionTitle
    {
        get
        {
            if (Settings.AutoSelect) return "Самый быстрый";
            if (Settings.SelectedCountry is { } c) return Loc.Country(c);
            return SelectedServer is { } s ? CleanName(s) : "Самый быстрый";
        }
    }

    // MARK: хранение

    void Load()
    {
        Directory.CreateDirectory(Paths.UserDir);
        try
        {
            if (!File.Exists(Paths.Store)) return;
            var s = Json.Deserialize<Store>(File.ReadAllText(Paths.Store));
            if (s == null) return;
            Apply(s);
        }
        catch (Exception e)
        {
            // Повреждённый файл не перезаписываем молча: откладываем копию.
            try { File.Copy(Paths.Store, Paths.Store + ".broken", true); } catch { }
            Message = "Настройки не прочитались, сохранена копия app.json.broken: " + e.Message;
        }
    }

    void Apply(Store s)
    {
        Servers = s.Servers; Subscriptions = s.Subscriptions; Profiles = s.Profiles;
        Settings = s.Settings.Copy(); Applied = s.Settings.Copy();
        Days = s.Days; ServerUsage = s.ServerUsage; Hidden = s.Hidden.ToHashSet(); lastExpiryWarn = s.LastExpiryWarn;
        lastCandidates = s.LastCandidateIDs.Select(id => s.Servers.FirstOrDefault(x => x.Id == id)).OfType<Server>().ToList();
        Pings = s.Pings;
    }

    Store Snapshot() => new()
    {
        Servers = Servers, Subscriptions = Subscriptions, Profiles = Profiles, Settings = Applied, Days = Days, ServerUsage = ServerUsage,
        Hidden = Hidden.ToList(), LastExpiryWarn = lastExpiryWarn, LastCandidateIDs = lastCandidates.Select(s => s.Id).ToList(), Pings = Pings,
    };

    public void ScheduleSave() { if (!loaded) return; saveTimer.Stop(); saveTimer.Start(); }

    /// Атомарная запись: во временный файл, потом замена. Папка %APPDATA% доступна только пользователю.
    public void SaveNow()
    {
        var tmp = Paths.Store + ".tmp";
        File.WriteAllText(tmp, Json.Serialize(Snapshot(), pretty: true), new UTF8Encoding(false));
        File.Move(tmp, Paths.Store, true);
    }

    /// Поле настроек поменялось. Выбор сервера и состояние списка — действия главного экрана, а не черновик.
    public void SettingsEdited(AppSettings before)
    {
        Applied = SettingsPolicy.MergingRuntimeChanges(before, Settings, Applied);
        ScheduleSave();
        Raise();
    }

    /// Изменить черновик действием главного экрана (выбор сервера, избранное), сохраняя только это.
    public void RuntimeChange(Action<AppSettings> change)
    {
        var before = Settings.Copy();
        change(Settings);
        SettingsEdited(before);
    }

    public async Task ApplySettings()
    {
        if (Busy) return;
        var old = Applied;
        var candidate = Settings.Copy();
        if (old.LaunchAtLogin != candidate.LaunchAtLogin)
        {
            try { SystemIntegration.SetLaunchAtLogin(candidate.LaunchAtLogin); }
            catch (Exception e) { Message = L.F("Автозапуск: %@", e.Message); return; }
        }
        Applied = candidate;
        try { saveTimer.Stop(); SaveNow(); }
        catch (Exception e)
        {
            Applied = old;
            Message = L.F("Не удалось сохранить настройки: %@", e.Message);
            Raise();
            return;
        }
        Raise();
        if (IsConnected) await Connect();
        else Message = "Настройки приняты";
    }

    public void DiscardDraft() { Settings = Applied.Copy(); Raise(); }

    // MARK: служба

    static async Task<DaemonStatus> Call(DaemonRequest req, TimeSpan? timeout = null) =>
        await Task.Run(() => Ipc.SendAsync(req, timeout ?? TimeSpan.FromSeconds(60)));

    public async Task RefreshStatus()
    {
        try
        {
            var s = await Call(new DaemonRequest { Cmd = DaemonCommand.Status }, TimeSpan.FromSeconds(5));
            DaemonReachable = true;
            Account(s);
            Status = s;
        }
        catch
        {
            DaemonReachable = false;
            Status = new DaemonStatus();
        }
        if (Status.ProxyGeneration != lastProxyGeneration)
        {
            if (lastProxyGeneration >= 0 || Status.ProxyGeneration > 0) SystemIntegration.RefreshWinInet();
            lastProxyGeneration = Status.ProxyGeneration;
        }
        StateChanged();
        Raise();
    }

    void Account(DaemonStatus s)
    {
        var now = DateTime.Now;
        long du = 0, dd = 0;
        if (lastSample is { } l && s.Uplink >= l.up && s.Downlink >= l.down)
        {
            du = s.Uplink - l.up; dd = s.Downlink - l.down;
            var dt = Math.Max((now - l.t).TotalSeconds, 0.1);
            SpeedUp = du / dt; SpeedDown = dd / dt;
        }
        else { SpeedUp = 0; SpeedDown = 0; }
        lastSample = (now, s.Uplink, s.Downlink);
        History.Add(SpeedUp + SpeedDown);
        if (History.Count > 60) History.RemoveRange(0, History.Count - 60);
        if (du + dd > 0)
        {
            var key = now.ToString("yyyy-MM-dd");
            if (!Days.TryGetValue(key, out var st)) Days[key] = st = new DayStat();
            st.Up += du; st.Down += dd;
            if (ActiveServerName is { } name) ServerUsage[name] = ServerUsage.GetValueOrDefault(name) + du + dd;
            if (now.Second % 30 == 0) ScheduleSave();
        }
    }

    void StateChanged()
    {
        var st = Status.State;
        if (st == TunnelState.Failed && lastState != TunnelState.Failed && Status.Info is { } why) Message = why;
        var notify = Applied.Notifications;
        try
        {
            if (st == TunnelState.Running && (lastState != TunnelState.Running || (Status.ActiveOutbound != null && Status.ActiveOutbound != lastActive)))
                _ = CheckIP();
            if (st == TunnelState.Stopped && lastState != TunnelState.Stopped) IpVPN = null;
            if (!notify) return;
            if (st == lastState)
            {
                if (st == TunnelState.Running && Status.ActiveOutbound is { } a && lastActive is { } prev && a != prev && ActiveServerName is { } name)
                    Notify?.Invoke("Tutun: сервер сменился", "Сейчас: " + name);
                return;
            }
            switch (st)
            {
                case TunnelState.Running when lastState is TunnelState.Starting or TunnelState.Stopped: Notify?.Invoke("Tutun подключён", Status.ServerLabel ?? ""); break;
                case TunnelState.Running: Notify?.Invoke("Tutun: связь восстановлена", ""); break;
                case TunnelState.Reconnecting: Notify?.Invoke("Tutun переподключается", "Связь с сервером пропала"); break;
                case TunnelState.Stopped: Notify?.Invoke("Tutun отключён", ""); break;
                case TunnelState.Failed: Notify?.Invoke("Tutun: ошибка подключения", Status.Info ?? Message ?? ""); break;
            }
        }
        finally { lastState = st; lastActive = Status.ActiveOutbound; }
    }

    public Task Toggle() => IsConnected ? Disconnect() : Connect();

    public async Task Connect()
    {
        if (Busy) return;
        // Новое подключение всегда использует принятые настройки, не затрагивая черновик.
        var settings = Applied.Copy();
        var selected = Servers.FirstOrDefault(s => s.Id == settings.SelectedServerID);
        var profile = Profiles.FirstOrDefault(p => p.Id == settings.ActiveProfileID);
        if (!DaemonReachable) { Message = ServiceInstalled ? "Служба Tutun не отвечает — переустановите её в «Настройки → О Tutun»" : "Служба не установлена — нажмите «Установить службу»"; return; }
        if (DaemonOutdated) { Message = "Служба устарела — нажмите «Обновить службу» в настройках"; return; }
        if (Servers.Count == 0) { Message = "Нет серверов — добавьте подписку"; return; }
        if (!settings.AutoSelect && settings.SelectedCountry == null && selected != null && LinkParser.RejectReason(selected) is { } why)
        { Message = L.F("«%@»: %@. Выберите другой сервер.", DisplayName(selected), why); return; }
        var (candidates, failoverOnly) = PickCandidates(settings);
        if (candidates.Count == 0) { Message = "Нет подходящих серверов"; return; }
        var chain = settings.ChainServerID is { } cid ? Servers.FirstOrDefault(s => s.Id == cid) : null;
        if (chain != null && candidates.Any(c => c.Id == chain.Id)) chain = null;
        Busy = true; Raise();
        try
        {
            var dropped = new List<string>();
            // Если ядро забракует какой-то сервер (ошибка «tag pN»), убираем его и пробуем снова.
            for (int attempt = 0; attempt < 6; attempt++)
            {
                var plan = new ConnectionInput
                {
                    Servers = candidates, Settings = settings, Profile = profile, Chain = chain,
                    FailoverOnly = failoverOnly && candidates.Count == 2, ClashSecret = ClashSecret(settings),
                };
                try { ConnectionValidation.Validate(plan); }
                catch (Exception e) { Message = e.Message; return; }
                var label = (failoverOnly || candidates.Count == 1) ? DisplayName(candidates[0])
                    : (!settings.AutoSelect && settings.SelectedCountry is { } c ? Loc.Country(c) : "Самый быстрый");
                DaemonStatus s;
                try { s = await Call(new DaemonRequest { Cmd = DaemonCommand.Start, Connection = plan, ServerLabel = label }); }
                catch (Exception e) { Message = e.Message; return; }
                Status = s;
                if (s.Ok)
                {
                    lastCandidates = candidates; lastSample = null;
                    ScheduleSave();
                    Message = dropped.Count == 0 ? null : "Пропущены серверы, которые ядро не приняло: " + string.Join(", ", dropped);
                    _ = Task.Delay(4000).ContinueWith(_ => CheckIP(), TaskScheduler.FromCurrentSynchronizationContext());
                    return;
                }
                var err = s.Error ?? "";
                if (candidates.Count > 1 && BadTag(err) is { } i && i < candidates.Count)
                {
                    dropped.Add(DisplayName(candidates[i]));
                    candidates = candidates.Where((_, k) => k != i).ToList();
                    if (candidates.Count < 2) failoverOnly = false;
                    continue;
                }
                Message = Friendly(err, candidates.Count == 1 ? DisplayName(candidates[0]) : null);
                return;
            }
            Message = "Не удалось подключиться: ядро не приняло несколько серверов подряд";
        }
        finally { Busy = false; Raise(); }
    }

    static string ClashSecret(AppSettings s) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes("clash" + s.Hwid))[..12]);

    static int? BadTag(string err)
    {
        var m = System.Text.RegularExpressions.Regex.Match(err, @"tag p(\d+)");
        return m.Success ? int.Parse(m.Groups[1].Value) : null;
    }

    /// Короткое сообщение вместо вывода ядра: без предупреждений, только суть.
    static string Friendly(string err, string? server)
    {
        var core = string.Join(" ", err.Split(" | ").Where(p => !p.Contains("[Warning]")));
        var gt = core.LastIndexOf("> ", StringComparison.Ordinal);
        if (gt >= 0) core = core[(gt + 2)..];
        var prefix = err.StartsWith("sing-box") ? "Не удалось включить перехват трафика" : "Не удалось подключиться";
        return prefix + (server != null ? L.F(" к «%@»", server) : "") + ": " + core.Trim();
    }

    public async Task Disconnect()
    {
        if (Busy) return;
        Busy = true; Raise();
        try { Status = await Call(new DaemonRequest { Cmd = DaemonCommand.Stop }); Message = null; IpVPN = null; }
        catch (Exception e) { Message = e.Message; }
        finally { Busy = false; Raise(); }
    }

    (List<Server>, bool) PickCandidates(AppSettings settings)
    {
        var usable = UsableServers;
        var selected = Servers.FirstOrDefault(s => s.Id == settings.SelectedServerID);
        if (!settings.AutoSelect && settings.SelectedCountry is { } code && CountryCandidates(code, usable, settings) is { } r) return r;
        if (!settings.AutoSelect && selected != null)
        {
            if (!settings.Failover) return ([selected], false);
            var backup = Sorted(usable.Where(s => s.Id != selected.Id && Alive(s))).FirstOrDefault();
            return backup == null ? ([selected], false) : ([selected, backup], true);
        }
        // «Самый быстрый» выбирает из всех серверов; недоступные — в конец; не больше 25.
        var byPing = usable.OrderBy(PingValue).ToList();
        var alive = byPing.Where(Alive).ToList();
        return ((alive.Count == 0 ? byPing : alive).Take(25).ToList(), false);
    }

    (List<Server>, bool)? CountryCandidates(string code, List<Server> usable, AppSettings settings)
    {
        var inCountry = usable.Where(s => s.CountryCode == code).ToList();
        if (settings.CountryPreferFavorites && inCountry.Where(s => s.Favorite).ToList() is { Count: > 0 } favs) inCountry = favs;
        if (inCountry.Count == 0) return null;
        var alive = inCountry.Where(Alive).ToList();
        var pool = alive.Count == 0 ? inCountry : alive;
        (List<Server>, bool) Single(Server s)
        {
            if (!settings.Failover) return ([s], false);
            var backup = pool.Where(x => x.Id != s.Id).OrderBy(PingValue).FirstOrDefault();
            return backup == null ? ([s], false) : ([s, backup], true);
        }
        switch (settings.CountryPick)
        {
            case CountryPick.LastUsed when settings.LastServerByCountry.TryGetValue(code, out var id) && inCountry.FirstOrDefault(s => s.Id == id) is { } last:
                return Single(last);
            case CountryPick.First:
                return Single(pool.OrderBy(CleanName, StringComparer.CurrentCultureIgnoreCase).First());
            case CountryPick.Random:
                return Single(pool[Random.Shared.Next(pool.Count)]);
            default:
                return (pool.OrderBy(PingValue).Take(10).ToList(), false);
        }
    }

    public async Task Select(Server? server)
    {
        RuntimeChange(s =>
        {
            if (server != null)
            {
                s.SelectedServerID = server.Id; s.SelectedCountry = null; s.AutoSelect = false;
                if (server.CountryCode is { } code) s.LastServerByCountry[code] = server.Id;
            }
            else { s.AutoSelect = true; s.SelectedCountry = null; }
        });
        await Connect();
    }

    public async Task SelectCountry(string code)
    {
        RuntimeChange(s => { s.SelectedCountry = code; s.SelectedServerID = null; s.AutoSelect = false; });
        await Connect();
    }

    public async Task SelectFastest()
    {
        RuntimeChange(s => { s.AutoSelect = true; s.SelectedCountry = null; });
        await Connect();
    }

    // MARK: избранное и группы

    public bool IsFavoriteCountry(string code) => Settings.FavoriteCountries.Contains(code);

    public void ToggleFavoriteCountry(string code) =>
        RuntimeChange(s => { if (!s.FavoriteCountries.Remove(code)) s.FavoriteCountries.Add(code); });

    public List<Country> FavoriteCountryList
    {
        get { var all = CountriesOf(UsableServers); return Settings.FavoriteCountries.Select(c => all.FirstOrDefault(x => x.Id == c)).OfType<Country>().ToList(); }
    }

    public List<Server> FavoriteServerList =>
        UsableServers.Where(s => s.Favorite).OrderBy(CleanName, StringComparer.CurrentCultureIgnoreCase).ToList();

    public List<ServerGroup> ServerGroups
    {
        get
        {
            var usable = UsableServers;
            var outp = new List<ServerGroup>();
            foreach (var sub in Subscriptions.Where(s => s.Enabled))
            {
                var list = usable.Where(s => s.SubscriptionID == sub.Id).ToList();
                if (list.Count > 0) outp.Add(new ServerGroup(sub.Id.ToString(), sub.Name, list.Count, CountriesOf(list), sub.Id));
            }
            var known = Subscriptions.Select(s => s.Id).ToHashSet();
            var manual = usable.Where(s => s.SubscriptionID is not { } id || !known.Contains(id)).ToList();
            if (manual.Count > 0) outp.Add(new ServerGroup("manual", "Добавленные вручную", manual.Count, CountriesOf(manual), null));
            return outp;
        }
    }

    public bool IsCollapsed(ServerGroup g) =>
        g.SubscriptionId is { } id ? Subscriptions.FirstOrDefault(s => s.Id == id)?.Collapsed == true : CollapsedGroups.Contains(g.Id);

    public void ToggleCollapsed(ServerGroup g)
    {
        if (g.SubscriptionId is { } id && Subscriptions.FirstOrDefault(s => s.Id == id) is { } sub) { sub.Collapsed = !sub.Collapsed; ScheduleSave(); }
        else if (!CollapsedGroups.Remove(g.Id)) CollapsedGroups.Add(g.Id);
        Raise();
    }

    /// Страны по алфавиту — список не прыгает при обновлении задержек.
    public List<Country> CountriesOf(List<Server> servers) =>
        servers.GroupBy(s => s.CountryCode ?? "??")
            .Select(g =>
            {
                var pings = g.Select(s => Pings.TryGetValue(s.Id, out var p) ? p : -2).Where(p => p >= 0).ToList();
                return new Country(g.Key, g.Key == "??" ? "Другие" : Loc.Country(g.Key),
                    g.OrderBy(CleanName, StringComparer.CurrentCultureIgnoreCase).ToList(), pings.Count > 0 ? pings.Min() : null);
            })
            .OrderBy(c => c.Id == "??").ThenBy(c => c.Name, StringComparer.CurrentCultureIgnoreCase).ToList();

    // MARK: подписки

    FetchOptions Fetch => new(Applied.Hwid, Applied.SendHWID, Applied.UserAgent, TimeSpan.FromSeconds(Math.Max(5, Applied.SubTimeout)), Applied.AllowHttpSubscriptions);

    public async Task AddSubscription(string url)
    {
        var trimmed = url.Trim();
        if (!trimmed.StartsWith("http", StringComparison.OrdinalIgnoreCase)) { await ImportText(trimmed); return; }
        if (Subscriptions.Any(s => s.Url == trimmed)) { Message = "Такая подписка уже есть"; return; }
        var sub = new Subscription { Name = "Подписка", Url = trimmed };
        Subscriptions.Add(sub);
        await Update(sub.Id);
    }

    public async Task Update(Guid id)
    {
        if (Subscriptions.FirstOrDefault(s => s.Id == id) is not { } sub) return;
        UpdatingSubs = true; Raise();
        try
        {
            var r = await SubscriptionFetcher.FetchAsync(sub, Fetch);
            var favs = Servers.Where(s => s.Favorite).Select(s => s.Id).ToHashSet();
            var fresh = r.Servers;
            foreach (var s in fresh) if (favs.Contains(s.Id)) s.Favorite = true;
            var others = Servers.Where(s => s.SubscriptionID != id).ToList();
            if (Applied.IgnoreDuplicates) fresh = Dedupe(fresh, others);
            Servers = others.Concat(fresh).ToList();
            var j = Subscriptions.FindIndex(s => s.Id == id);
            if (j >= 0)
            {
                r.Meta.ListMode = Subscriptions[j].ListMode; r.Meta.ListSort = Subscriptions[j].ListSort;
                r.Meta.Enabled = Subscriptions[j].Enabled; r.Meta.Collapsed = Subscriptions[j].Collapsed;
                Subscriptions[j] = r.Meta;
            }
            // Профили маршрутов от провайдера заменяют прежние профили этой подписки.
            if (r.Profiles.Count > 0)
            {
                var oldID = Applied.ActiveProfileID;
                var activeName = Profiles.FirstOrDefault(p => p.Id == oldID)?.Name;
                Profiles = Profiles.Where(p => p.FromSubscription != id).Concat(r.Profiles).ToList();
                if (activeName != null && Profiles.FirstOrDefault(p => p.Name == activeName) is { } np)
                {
                    Applied.ActiveProfileID = np.Id;
                    if (Settings.ActiveProfileID == oldID) Settings.ActiveProfileID = np.Id;
                }
            }
            Message = r.Skipped.Count == 0 ? null : L.F("Пропущено: %@ — ", r.Skipped.Count) + string.Join("; ", r.Skipped.Take(2));
            CheckExpiry(r.Meta);
            ScheduleSave();
            Raise();
            if (Applied.PingAfterUpdate) await PingServers(fresh);
        }
        catch (Exception e)
        {
            if (Subscriptions.FirstOrDefault(s => s.Id == id) is { } s2) s2.LastError = e.Message;
            Message = e.Message;
        }
        finally { UpdatingSubs = false; Raise(); }
    }

    static List<Server> Dedupe(List<Server> list, List<Server> others)
    {
        var seen = others.Select(Key).ToHashSet();
        return list.Where(s => seen.Add(Key(s))).ToList();
        static string Key(Server s) => $"{s.Proto}|{s.Host}|{s.Port}|{s.OutboundJSON}";
    }

    public async Task UpdateAll() { foreach (var s in Subscriptions.ToList()) await Update(s.Id); }

    async Task UpdateDueSubscriptions(bool force = false)
    {
        foreach (var s in Subscriptions.Where(s => s.Enabled).ToList())
        {
            var due = force || s.LastUpdate is not { } lu || (DateTimeOffset.Now - lu).TotalHours > s.UpdateIntervalHours;
            if (due) await Update(s.Id);
        }
    }

    void CheckExpiry(Subscription s)
    {
        if (!Applied.Notifications || s.Expire is not { } exp) return;
        var days = (int)(exp - DateTimeOffset.Now).TotalDays;
        if (days > Applied.ExpiryWarnDays) return;
        if (lastExpiryWarn.TryGetValue(s.Id.ToString(), out var last) && (DateTimeOffset.Now - last).TotalDays < 1) return;
        lastExpiryWarn[s.Id.ToString()] = DateTimeOffset.Now; ScheduleSave();
        Notify?.Invoke(L.F("Подписка «%@» заканчивается", s.Name), days <= 0 ? "Срок истёк" : L.F("Осталось дней: %@", days));
    }

    public void RemoveSubscription(Guid id)
    {
        Subscriptions.RemoveAll(s => s.Id == id);
        Servers.RemoveAll(s => s.SubscriptionID == id);
        Profiles.RemoveAll(p => p.FromSubscription == id);
        ScheduleSave(); Raise();
    }

    /// Ссылки серверов, профили маршрутов, base64-список, JSON, конфиг WireGuard, ссылки tutun://, happ://add.
    public async Task ImportText(string text)
    {
        var t = text.Trim();
        if (t.Length == 0) { Message = "Пусто"; return; }
        foreach (var prefix in new[] { "happ://add/", "tutun://add/", "tutun://import/" })
        {
            if (!t.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) continue;
            var decoded = UrlParts.Decode(t[prefix.Length..]);
            if (decoded.StartsWith("http", StringComparison.OrdinalIgnoreCase)) { await AddSubscription(decoded); return; }
            await ImportText(LinkParser.Base64Decode(decoded) ?? decoded); return;
        }
        if (t.StartsWith("http", StringComparison.OrdinalIgnoreCase) && !t.Contains('\n')) { await AddSubscription(t); return; }
        if (t.StartsWith('{') && t.Contains("\"tutun.profile\"")) { ImportProfile(Encoding.UTF8.GetBytes(t)); return; }
        var b = LinkParser.ParseBatch(t, null);
        var known = Servers.Select(s => s.Id).ToHashSet();
        var added = b.Servers.Where(s => !known.Contains(s.Id)).ToList();
        if (Applied.IgnoreDuplicates) added = Dedupe(added, Servers);
        Servers.AddRange(added);
        foreach (var p in b.Profiles) AddProfile(p);
        var parts = new List<string>();
        if (added.Count > 0) parts.Add(L.F("серверов: %@", added.Count));
        if (b.Profiles.Count > 0) parts.Add(L.F("профилей маршрутов: %@", b.Profiles.Count));
        Message = parts.Count == 0 ? (b.Errors.FirstOrDefault() ?? "Ничего не распознано")
            : "Добавлено " + string.Join(", ", parts) + (b.Errors.Count == 0 ? "" : L.F(". Пропущено: %@", b.Errors.Count));
        ScheduleSave(); Raise();
        if (added.Count > 0) await PingAll();
    }

    /// Общий профиль tutun.profile v1 (с мака или Android). Локальные поля устройства не меняются.
    public void ImportProfile(byte[] data)
    {
        ConfigurationProfile p;
        try { p = ConfigurationProfile.Decode(data); }
        catch (Exception e) { Message = "Профиль не принят: " + e.Message; return; }
        var subIds = Subscriptions.Select(s => s.Id).ToHashSet();
        foreach (var s in p.Subscriptions) if (!subIds.Contains(s.Id)) Subscriptions.Add(s);
        var known = Servers.Select(s => s.Id).ToHashSet();
        var added = p.Servers.Where(s => !known.Contains(s.Id)).ToList();
        Servers.AddRange(added);
        foreach (var r in p.RoutingProfiles) if (Profiles.All(x => x.Id != r.Id)) Profiles.Add(r);
        var before = Settings.Copy();
        p.Preferences.ApplyTo(Settings);
        SettingsEdited(before);
        var unsupported = new List<string>();
        Message = $"Профиль прочитан: серверов {added.Count}, подписок {p.Subscriptions.Count}. Сетевые настройки — в черновике, примите их в «Настройках»."
                  + (unsupported.Count > 0 ? " Не поддерживается: " + string.Join(", ", unsupported) : "");
        ScheduleSave(); Raise();
    }

    public string ExportProfile()
    {
        var p = new ConfigurationProfile
        {
            Servers = Servers, Subscriptions = Subscriptions, RoutingProfiles = Profiles,
            Preferences = ConnectionPreferences.From(Applied),
        };
        return p.Encode();
    }

    // MARK: серверы

    public void ToggleFavorite(Server s) { s.Favorite = !s.Favorite; ScheduleSave(); Raise(); }

    public void Remove(Server s)
    {
        if (s.SubscriptionID == null) Servers.RemoveAll(x => x.Id == s.Id); else Hidden.Add(s.Id);
        ScheduleSave(); Raise();
    }

    public void Rename(Server s, string name)
    {
        var n = name.Trim();
        RuntimeChange(st => { if (n.Length == 0 || n == s.Name) st.ServerRenames.Remove(s.Id); else st.ServerRenames[s.Id] = n; });
    }

    public void RemoveDead()
    {
        var dead = Servers.Where(s => Pings.TryGetValue(s.Id, out var p) && p < 0).ToList();
        foreach (var s in dead) Remove(s);
        Message = dead.Count == 0 ? "Нерабочих серверов нет" : L.F("Убрано нерабочих серверов: %@", dead.Count);
    }

    /// Сохранить отредактированный сервер (ссылкой или JSON). Сервер из подписки становится ручной копией.
    public void SaveEdited(Server? original, string? link, string? json, string name)
    {
        Server s;
        if (!string.IsNullOrWhiteSpace(link)) s = LinkParser.Parse(link);
        else if (!string.IsNullOrWhiteSpace(json) && Json.ParseObject(json) is { } ob)
        {
            var isSB = ob["type"] != null && ob["protocol"] == null;
            var ep = isSB ? (ob.Str("server") ?? "", ob.Int("server_port") ?? 0) : LinkParser.Endpoint(ob);
            var canonical = Json.ToJSON(ob);
            s = new Server
            {
                Id = LinkParser.StableID(canonical), Name = name, Proto = ob.Str("protocol") ?? ob.Str("type") ?? "?", Host = ep.Item1, Port = ep.Item2,
                Transport = ob.Obj("streamSettings")?.Str("network") ?? (isSB ? "quic" : "tcp"), OutboundJSON = canonical,
                Engine = isSB ? Engine.Singbox : Engine.Xray,
            };
            if (s.Host.Length == 0 || s.Port is < 1 or > 65535) throw new LinkException("в JSON нет адреса или порта сервера");
        }
        else throw new LinkException("пусто");
        if (name.Trim().Length > 0) s.Name = name.Trim();
        s.Favorite = original?.Favorite ?? false;
        var i = original == null ? -1 : Servers.FindIndex(x => x.Id == original.Id);
        if (original != null && original.SubscriptionID == null && i >= 0) Servers[i] = s;
        else Servers.Add(s);
        if (Settings.SelectedServerID == original?.Id && original != null) RuntimeChange(st => st.SelectedServerID = s.Id);
        ScheduleSave(); Raise();
    }

    public async Task ImportQR(List<string> codes)
    {
        if (codes.Count == 0) { Message = "QR-код не найден"; return; }
        await ImportText(string.Join("\n", codes));
    }

    public void UnhideAll() { Hidden.Clear(); ScheduleSave(); Raise(); }

    public string ExportAllLinks() => string.Join("\n", Servers.Select(s => s.RawLink).OfType<string>());

    // MARK: проверка задержки

    public Task PingAll() => PingServers(VisibleServers.ToList());

    public async Task PingServers(List<Server> list)
    {
        if (Testing || SpeedTesting != null) return;
        Testing = true; Raise();
        try
        {
            if (Applied.PingType == PingType.Url) await UrlTest(list); else await TcpPing(list);
        }
        finally { Testing = false; ScheduleSave(); Raise(); }
    }

    public async Task PingOne(Server s)
    {
        if (Testing || SpeedTesting != null) return;
        Testing = true; Raise();
        try { if (Applied.PingType == PingType.Url) await UrlTest([s]); else await TcpPing([s]); }
        finally { Testing = false; ScheduleSave(); Raise(); }
    }

    async Task TcpPing(List<Server> list)
    {
        var items = list.Where(s => s.Proto is not ("hysteria2" or "tuic" or "wireguard")).ToList();
        using var gate = new SemaphoreSlim(16);
        await Task.WhenAll(items.Select(async s =>
        {
            await gate.WaitAsync();
            try { Pings[s.Id] = await TestHarness.TcpPingAsync(s.Host, s.Port); Raise(); }
            finally { gate.Release(); }
        }));
    }

    async Task UrlTest(List<Server> list)
    {
        var settings = Applied;
        var usable = list.Where(s => LinkParser.RejectReason(s) == null).ToList();
        foreach (var s in list.Where(s => LinkParser.RejectReason(s) != null)) Pings[s.Id] = -1;
        if (usable.Count == 0) return;
        try
        {
            // Не больше 120 серверов за раз: портов и процессов хватает, сеть не перегружается.
            foreach (var chunk in usable.Chunk(120))
            {
                using var h = await TestHarness.StartAsync(chunk.ToList(), settings);
                foreach (var s in chunk.Where(s => !h.Ports.ContainsKey(s.Id))) Pings[s.Id] = -1;
                using var gate = new SemaphoreSlim(10);
                var timeout = TimeSpan.FromSeconds(Math.Max(2, settings.TestTimeout));
                await Task.WhenAll(chunk.Where(s => h.Ports.ContainsKey(s.Id)).Select(async s =>
                {
                    await gate.WaitAsync();
                    try { Pings[s.Id] = await TestHarness.DelayAsync(h.Ports[s.Id], settings.TestURL, settings.TestMethodHead, timeout); Raise(); }
                    finally { gate.Release(); }
                }));
            }
        }
        catch (Exception e)
        {
            Message = e.Message;
            await TcpPing(list);
        }
    }

    public async Task SpeedTest(Server s)
    {
        if (SpeedTesting != null || Testing) return;
        SpeedTesting = s.Id; Raise();
        try
        {
            using var h = await TestHarness.StartAsync([s], Applied);
            if (!h.Ports.TryGetValue(s.Id, out var port)) { Message = "Сервер не принят ядром"; return; }
            if (await TestHarness.SpeedAsync(port) is { } bps) { Speeds[s.Id] = bps; Message = $"{DisplayName(s)}: {Format.Mbps(bps)}"; }
            else { Speeds[s.Id] = 0; Message = L.F("%@: не удалось скачать тестовый файл", DisplayName(s)); }
        }
        catch (Exception e) { Message = e.Message; }
        finally { SpeedTesting = null; Raise(); }
    }

    // MARK: профили маршрутов

    public void AddProfile(RoutingProfile p)
    {
        var i = Profiles.FindIndex(x => x.Name == p.Name && x.FromSubscription == p.FromSubscription);
        if (i >= 0) { p.Id = Profiles[i].Id; Profiles[i] = p; } else Profiles.Add(p);
        if (Settings.ActiveProfileID == null)
        {
            var before = Settings.Copy();
            Settings.ActiveProfileID = Profiles.First(x => x.Name == p.Name).Id;
            SettingsEdited(before);
        }
        ScheduleSave();
    }

    // MARK: IP, гео-базы

    public async Task CheckIP()
    {
        var d = SystemIntegration.FetchIP(null);
        var v = IsConnected ? SystemIntegration.FetchIP(Paths.SocksPort) : Task.FromResult<IPInfo?>(null);
        IpDirect = await d; IpVPN = await v;
        Raise();
    }

    async Task Periodic()
    {
        ConflictList = SystemIntegration.Conflicts();
        await UpdateDueSubscriptions();
        if (Applied.GeoAutoUpdate && DaemonReachable && (Applied.GeoLastUpdate is not { } g || (DateTimeOffset.Now - g).TotalDays > 7))
            await UpdateGeo(silent: true);
        Raise();
    }

    public bool GeoUpdating { get; private set; }
    public async Task UpdateGeo(bool silent = false)
    {
        if (GeoUpdating) { if (!silent) Message = "Обновление гео-баз уже выполняется"; return; }
        GeoUpdating = true; Raise();
        try
        {
            var s = await Call(new DaemonRequest { Cmd = DaemonCommand.UpdateGeo, GeoipURL = Applied.GeoipURL, GeositeURL = Applied.GeositeURL }, TimeSpan.FromSeconds(400));
            if (s.Ok) { RuntimeChange(st => st.GeoLastUpdate = DateTimeOffset.Now); if (!silent) Message = "Гео-базы обновлены"; }
            else if (!silent) Message = s.Error;
        }
        catch (Exception e) { if (!silent) Message = e.Message; }
        finally { GeoUpdating = false; Raise(); }
    }

    // MARK: ссылки tutun://

    public async Task HandleUrl(string url)
    {
        var lower = url.ToLowerInvariant();
        if (lower.StartsWith("tutun://"))
        {
            var host = lower["tutun://".Length..].Split('/', '?')[0];
            switch (host)
            {
                case "connect" or "on": await Connect(); return;
                case "disconnect" or "off": await Disconnect(); return;
                case "toggle": await Toggle(); return;
                case "routing":
                    if (lower.Contains("/off")) { RuntimeChange(s => s.ActiveProfileID = null); return; }
                    if (RoutingProfiles.ParseLink(url) is { } p) { AddProfile(p); Message = L.F("Профиль «%@» добавлен", p.Name); Raise(); }
                    return;
            }
        }
        if (lower.StartsWith("happ://routing"))
        {
            if (RoutingProfiles.ParseLink(url) is { } p) { AddProfile(p); Message = L.F("Профиль «%@» добавлен", p.Name); Raise(); }
            return;
        }
        await ImportText(url);
    }

    // MARK: резервная копия

    public void ExportBackup(string path) => File.WriteAllText(path, Json.Serialize(Snapshot(), pretty: true));

    public void ImportBackup(string path)
    {
        var s = Json.Deserialize<Store>(File.ReadAllText(path)) ?? throw new InvalidDataException("пустой файл");
        var hwid = Applied.Hwid;
        Apply(s);
        // ID устройства этого компьютера не меняем; Windows-специфичные поля — свои.
        if (hwid.Length > 0) { Settings.Hwid = hwid; Applied.Hwid = hwid; }
        Message = L.F("Восстановлено: серверов %@, подписок %@", s.Servers.Count, s.Subscriptions.Count);
        SaveNow(); Raise();
    }

    public void ResetStats() { Days.Clear(); ServerUsage.Clear(); ScheduleSave(); Raise(); }

    // MARK: служба

    public string? ServiceStage { get; private set; }

    public async Task InstallService(bool install = true)
    {
        if (Busy) return;
        ServiceStage = "Ожидаю подтверждения администратора…";
        Busy = true; Raise();
        try
        {
            var err = await Installer.RunElevatedAsync(install);
            if (err != null) { Message = err; return; }
            ServiceStage = install ? "Проверяю службу…" : "Проверяю удаление…"; Raise();
            await Task.Delay(1500);
            await RefreshStatus();
            Message = install ? (DaemonReachable ? "Служба установлена" : "Служба установлена, но не отвечает — журнал в C:\\ProgramData\\Tutun\\tutun.log") : "Служба удалена";
        }
        finally { ServiceStage = null; Busy = false; Raise(); }
    }
}

public static class Format
{
    public static string Speed(double bps)
    {
        if (bps < 1024) return $"{bps:0} {L.T("Б/с")}";
        if (bps < 1024 * 1024) return $"{bps / 1024:0} {L.T("КБ/с")}";
        return $"{bps / 1024 / 1024:0.0} {L.T("МБ/с")}";
    }

    public static string Mbps(double bps) => $"{bps * 8 / 1_000_000:0.0} {L.T("Мбит/с")}";

    public static string Bytes(long b)
    {
        if (b < 1024) return $"{b} {L.T("Б")}";
        if (b < 1L << 20) return $"{b / 1024.0:0.0} {L.T("КБ")}";
        if (b < 1L << 30) return $"{b / 1048576.0:0.0} {L.T("МБ")}";
        return $"{b / 1073741824.0:0.00} {L.T("ГБ")}";
    }

    public static string ServersWord(int n)
    {
        int m10 = n % 10, m100 = n % 100;
        // Русский и украинский — три формы; остальные языки — «1 server» / «N servers».
        var w = L.Code is "ru" or "uk"
            ? (m10 == 1 && m100 != 11 ? "сервер" : (m10 is >= 2 and <= 4 && m100 is not (>= 12 and <= 14)) ? "сервера" : "серверов")
            : (n == 1 ? "сервер" : "серверов");
        return $"{n} {L.T(w)}";
    }
}
