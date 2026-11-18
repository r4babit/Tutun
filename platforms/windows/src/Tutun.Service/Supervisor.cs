using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Security.Cryptography;
using Tutun.Core;

namespace Tutun.Service;

/// Держит xray, sing-box (TUN) и вспомогательный sing-box запущенными, перезапускает при падении,
/// проверяет связь и при обрыве переходит на самый быстрый из отвечающих серверов. Порт мак-службы tutund.
public sealed class Supervisor
{
    sealed class Desired
    {
        public bool Active { get; set; }
        public ConnectionMode Mode { get; set; } = ConnectionMode.Tun;
        public bool KillSwitch { get; set; } = true;
        public List<string> ExcludedRoutes { get; set; } = [];
        public string? ServerLabel { get; set; }
        public bool HasHelper { get; set; }
        public SelectorParams? Selector { get; set; }
        public string? Current { get; set; }   // через какой сервер (p0…pN) идём сейчас
    }

    readonly object gate = new();
    Desired desired = new();
    long revision;
    TunnelState currentState = TunnelState.Stopped;
    TunnelState state
    {
        get => currentState;
        set
        {
            if (value == currentState) return;
            currentState = value;
            revision++;
            Monitor.PulseAll(gate);
        }
    }
    DateTimeOffset? since;
    Process? xray, singBox, helper;
    int restarts, xrayFailStreak, healthFailStreak, tunFailStreak;
    string? failReason;
    bool? healthy;
    int? latencyMs;
    bool proxySet;
    readonly SystemProxy systemProxy;
    readonly EmergencyFirewall firewall = new();
    int generation;
    Timer? healthTimer;
    int geoUpdating;
    GeoUpdateProgress? geoProgress;
    (DateTime at, long up, long down, string? active) statsCache = (DateTime.MinValue, 0, 0, null);

    static string XrayConfigPath => Path.Combine(Paths.RunDir, "xray.json");
    static string SingBoxConfigPath => Path.Combine(Paths.RunDir, "sing-box.json");
    static string HelperConfigPath => Path.Combine(Paths.RunDir, "helper.json");
    static string PlanPath => Path.Combine(Paths.RunDir, "connection-plan.json");

    public Supervisor(string ownerSid) { systemProxy = new SystemProxy(ownerSid); }

    // MARK: жизненный цикл

    public void Boot()
    {
        lock (gate)
        {
            Directory.CreateDirectory(Paths.RunDir);
            LoadGeoCodes();
            try { if (File.Exists(Paths.DaemonState)) desired = Json.Deserialize<Desired>(File.ReadAllText(Paths.DaemonState)) ?? new(); }
            catch { desired = new(); }
            ProtectAfterTunFailure();
            KillStrays();
            try { systemProxy.Restore(); } catch (Exception e) { Log.Write("Прокси: " + e.Message); }
            if (desired.Active && File.Exists(PlanPath))
            {
                try
                {
                    var plan = Json.Deserialize<ConnectionInput>(File.ReadAllText(PlanPath)) ?? throw new InvalidDataException("пустой план");
                    ConnectionValidation.Validate(plan);
                    var built = BuildLogged(plan);
                    WriteFile(XrayConfigPath, built.Xray);
                    if (built.SingBox != null) WriteFile(SingBoxConfigPath, built.SingBox);
                    if (built.Helper != null) WriteFile(HelperConfigPath, built.Helper);
                }
                catch (Exception e)
                {
                    desired.Active = false; SaveDesired(); state = TunnelState.Failed;
                    firewall.Release();
                    Log.Write("Не восстановить проверенный конфиг: " + e.Message);
                    StartHealthTimer(); return;
                }
                Log.Write("Служба запущена, восстанавливаю подключение");
                Launch();
            }
            else
            {
                desired.Active = false; SaveDesired();
                firewall.Release();
                Log.Write("Служба запущена");
            }
            StartHealthTimer();
        }
    }

    public void Shutdown()
    {
        lock (gate)
        {
            healthTimer?.Dispose();
            // Подключение восстановится при следующем запуске службы; прокси возвращаем сразу.
            StopProcesses();
            firewall.Release();
            Log.Write("Служба остановлена");
        }
    }

    // MARK: команды

    public DaemonStatus Handle(DaemonRequest req)
    {
        switch (req.Cmd)
        {
            case DaemonCommand.WaitForChange:
                lock (gate)
                {
                    if (req.Revision == revision) Monitor.Wait(gate, TimeSpan.FromSeconds(8));
                    return new DaemonStatus { Revision = revision };
                }
            case DaemonCommand.Ping:
            case DaemonCommand.Status:
                lock (gate) return Status();
            case DaemonCommand.Stop:
                lock (gate)
                {
                    desired.Active = false; SaveDesired();
                    StopProcesses(); state = TunnelState.Stopped; since = null;
                    firewall.Release();
                    Log.Write("Отключено пользователем");
                    return Status();
                }
            case DaemonCommand.Start:
                lock (gate) return Start(req);
            case DaemonCommand.UpdateGeo:
                return UpdateGeo(req);
            default:
                lock (gate) return Fail("Неизвестная команда");
        }
    }

    DaemonStatus Start(DaemonRequest request)
    {
        var plan = request.Connection;
        if (plan == null) return Fail("Обновите приложение: требуется описание подключения");
        try { ConnectionValidation.Validate(plan); }
        catch (Exception e) { return Fail(e.Message); }
        BuiltConfig built;
        try { built = BuildLogged(plan); }
        catch (Exception e) { return Fail("Не собрать конфиг: " + e.Message); }
        var mode = plan.Settings.Mode;
        var selector = new SelectorParams
        {
            Candidates = plan.Servers.Count, IntervalSec = plan.Settings.ProbeIntervalSec, FailLimit = plan.Settings.HealthFailLimit,
            TestURL = plan.Settings.TestURL, TimeoutSec = plan.Settings.TestTimeout,
        };
        if (mode == ConnectionMode.Tun && built.SingBox == null) return Fail("Нет конфига TUN");

        // Проверяем конфиги до того, как трогать текущее подключение.
        // Ядра определяют формат по расширению: временные файлы обязаны кончаться на .json.
        string tmpX = Path.Combine(Paths.RunDir, "xray.new.json"), tmpS = Path.Combine(Paths.RunDir, "sing-box.new.json"),
               tmpH = Path.Combine(Paths.RunDir, "helper.new.json"), tmpPlan = Path.Combine(Paths.RunDir, "connection-plan.new.json");
        try
        {
            WriteFile(tmpPlan, Json.Serialize(plan));
            WriteFile(tmpX, built.Xray);
            var (c, o) = RunSync(Paths.Xray, ["run", "-test", "-c", tmpX], XrayEnv);
            if (c != 0) return Fail("xray не принял конфиг: " + LastLines(o, 3));
            if (built.SingBox != null)
            {
                WriteFile(tmpS, built.SingBox);
                var (c2, o2) = RunSync(Paths.SingBox, ["check", "-c", tmpS]);
                if (c2 != 0) return Fail("sing-box не принял конфиг: " + LastLines(o2, 3));
            }
            if (built.Helper != null)
            {
                WriteFile(tmpH, built.Helper);
                var (c3, o3) = RunSync(Paths.SingBox, ["check", "-c", tmpH]);
                if (c3 != 0) return Fail("sing-box (TUIC/Hysteria2) не принял конфиг: " + LastLines(o3, 3));
            }
        }
        catch (Exception e) { return Fail("Не записать конфиг: " + e.Message); }

        if (plan.Settings.KillSwitch && mode == ConnectionMode.Tun)
        {
            try { firewall.Block(plan.Settings.ExcludedRoutes); }
            catch (Exception e) { return Fail(e.Message); }
        }
        StopProcesses();

        // Порты Tutun могут быть заняты другой программой (другой VPN-клиент): тогда xray не запустится.
        var ports = new List<int> { Paths.SocksPort, Paths.HttpPort, Paths.ApiPort };
        if (mode == ConnectionMode.Tun) ports.Add(Paths.ClashPort);
        if (plan.Settings.AllowLAN) { ports.Add(plan.Settings.LanSocksPort); ports.Add(plan.Settings.LanHttpPort); }
        var listening = IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Select(e => e.Port).ToHashSet();
        var busy = ports.Where(listening.Contains).ToList();
        if (busy.Count > 0)
        {
            desired.Active = false; SaveDesired(); state = TunnelState.Stopped; firewall.Release();
            return Fail($"Порт {string.Join(", ", busy)} занят другой программой — закройте другой VPN-клиент и подключитесь снова");
        }

        // При переключении серверов в режиме TUN с аварийной блокировкой трафик держим, пока поднимается новый туннель.
        try
        {
            if (plan.Settings.KillSwitch && mode == ConnectionMode.Tun) firewall.Block();
            else firewall.Release();
        }
        catch (Exception e)
        {
            desired.Active = false; SaveDesired(); state = TunnelState.Stopped;
            return Fail(e.Message + ". Выключите «Аварийная блокировка» в настройках и подключитесь снова.");
        }
        Replace(tmpX, XrayConfigPath);
        Replace(tmpPlan, PlanPath);
        if (built.SingBox != null) Replace(tmpS, SingBoxConfigPath);
        if (built.Helper != null) Replace(tmpH, HelperConfigPath); else TryDelete(HelperConfigPath);

        desired = new Desired
        {
            Active = true, Mode = mode, KillSwitch = plan.Settings.KillSwitch, ServerLabel = request.ServerLabel,
            ExcludedRoutes = [.. plan.Settings.ExcludedRoutes],
            HasHelper = built.Helper != null, Selector = selector, Current = selector.Candidates > 1 ? "p0" : null,
        };
        SaveDesired();
        StartHealthTimer();
        restarts = 0; since = null; tunFailStreak = 0; xrayFailStreak = 0; failReason = null;
        Log.Write($"Подключение: {request.ServerLabel ?? "?"}, режим {(mode == ConnectionMode.Tun ? "весь трафик" : "прокси")}");
        Launch();
        return Status();
    }

    // MARK: гео-базы

    /// Скачивает geoip.dat / geosite.dat (через VPN, если он поднят), проверяет и подменяет.
    DaemonStatus UpdateGeo(DaemonRequest req)
    {
        if (Interlocked.CompareExchange(ref geoUpdating, 1, 0) != 0)
        {
            lock (gate) return Fail("Обновление гео-баз уже выполняется");
        }
        var installed = new List<(string Path, bool Existed)>();
        var staged = new List<(string Name, string Path)>();
        bool viaProxy;
        lock (gate) viaProxy = xray != null && state == TunnelState.Running;
        using var http = MakeHttp(viaProxy ? Paths.SocksPort : null, TimeSpan.FromSeconds(180));
        try
        {
            foreach (var (name, url) in new[] { ("geoip.dat", req.GeoipURL), ("geosite.dat", req.GeositeURL) })
            {
                if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps)
                    throw new InvalidDataException("Для гео-баз требуется HTTPS");
                var tmp = Path.Combine(Paths.RunDir, name + ".new");
                staged.Add((name, tmp));
                SetGeoProgress(new(name, "Загрузка"));
                using var response = http.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead).GetAwaiter().GetResult();
                response.EnsureSuccessStatusCode();
                if (response.RequestMessage?.RequestUri?.Scheme != Uri.UriSchemeHttps)
                    throw new InvalidDataException("Небезопасная переадресация гео-базы");
                var total = response.Content.Headers.ContentLength;
                using (var input = response.Content.ReadAsStream())
                using (var output = File.Create(tmp))
                {
                    var buffer = new byte[65536];
                    long downloaded = 0;
                    using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(3));
                    int count;
                    while ((count = input.ReadAsync(buffer.AsMemory(), timeout.Token).AsTask().GetAwaiter().GetResult()) > 0)
                    {
                        downloaded += count;
                        if (downloaded > 256L * 1024 * 1024) throw new InvalidDataException("Гео-база превышает 256 МБ");
                        output.Write(buffer, 0, count);
                        SetGeoProgress(new(name, "Загрузка", downloaded, total));
                    }
                    if (downloaded < 100_000 || total.HasValue && downloaded != total.Value)
                        throw new InvalidDataException("Гео-база неполная или слишком маленькая");
                }
                SetGeoProgress(new(name, "Проверка"));
                using var checksum = http.GetAsync(url + ".sha256sum").GetAwaiter().GetResult();
                if (checksum.IsSuccessStatusCode)
                {
                    var expected = checksum.Content.ReadAsStringAsync().GetAwaiter().GetResult().Trim().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).FirstOrDefault();
                    using var file = File.OpenRead(tmp);
                    var actual = Convert.ToHexString(SHA256.HashData(file));
                    if (!string.Equals(expected, actual, StringComparison.OrdinalIgnoreCase))
                        throw new InvalidDataException("Контрольная сумма гео-базы не совпала");
                }
                else if (checksum.StatusCode != HttpStatusCode.NotFound)
                    checksum.EnsureSuccessStatusCode();
                if (GeoData.ReadGeoipCodes(tmp) is not { Count: > 0 })
                    throw new InvalidDataException("Неверный формат гео-базы");
            }
            lock (gate)
            {
                foreach (var (name, tmp) in staged)
                {
                    SetGeoProgress(new(name, "Установка"));
                    var dst = Path.Combine(Paths.BinDir, name);
                    var existed = File.Exists(dst);
                    if (existed) File.Copy(dst, dst + ".bak", true);
                    installed.Add((dst, existed));
                    File.Move(tmp, dst, true);
                }
                if (File.Exists(XrayConfigPath))
                {
                    var (code, output) = RunSync(Paths.Xray, ["run", "-test", "-c", XrayConfigPath], XrayEnv);
                    if (code != 0) throw new InvalidDataException("Новые гео-базы не подошли: " + LastLines(output, 2));
                }
                LoadGeoCodes();
                SetGeoProgress(new("", "Готово", CompletedAt: DateTimeOffset.UtcNow));
                Log.Write("Гео-базы обновлены. Применятся при следующем запуске ядра.");
                var result = Status();
                result.Info = "Гео-базы обновлены";
                return result;
            }
        }
        catch (Exception e)
        {
            lock (gate)
            {
                var errors = new List<string> { e.Message };
                foreach (var (path, existed) in installed.AsEnumerable().Reverse())
                {
                    try
                    {
                        if (existed) File.Copy(path + ".bak", path, true);
                        else File.Delete(path);
                    }
                    catch (Exception rollback) { errors.Add("Не восстановить " + Path.GetFileName(path) + ": " + rollback.Message); }
                }
                var error = string.Join(". ", errors);
                SetGeoProgress(new(geoProgress?.File ?? "", "Ошибка", Error: error));
                return Fail(error);
            }
        }
        finally
        {
            foreach (var (_, path) in staged) TryDelete(path);
            Interlocked.Exchange(ref geoUpdating, 0);
        }
    }

    void SetGeoProgress(GeoUpdateProgress progress)
    {
        lock (gate) geoProgress = progress;
    }

    static void LoadGeoCodes()
    {
        ConfigBuilder.GeoipCodes = GeoData.ReadGeoipCodes(Path.Combine(Paths.BinDir, "geoip.dat"));
        ConfigBuilder.GeositeCodes = GeoData.ReadGeoipCodes(Path.Combine(Paths.BinDir, "geosite.dat"));
        Log.Write($"Гео-базы: geoip {ConfigBuilder.GeoipCodes?.Count ?? 0} кодов, geosite {ConfigBuilder.GeositeCodes?.Count ?? 0}");
    }

    /// Сборка конфига с записью в журнал, какие правила пропущены из-за отсутствующих кодов в гео-базах.
    static BuiltConfig BuildLogged(ConnectionInput plan)
    {
        lock (ConfigBuilder.Skipped) ConfigBuilder.Skipped.Clear();
        var built = ConfigBuilder.Build(plan);
        lock (ConfigBuilder.Skipped)
            if (ConfigBuilder.Skipped.Count > 0) Log.Write("Нет в гео-базах, правила пропущены: " + string.Join(", ", ConfigBuilder.Skipped));
        return built;
    }

    // MARK: процессы

    void Launch()
    {
        generation++;
        state = TunnelState.Starting;
        healthy = null; latencyMs = null; healthFailStreak = 0;
        if (desired.HasHelper && helper == null && File.Exists(HelperConfigPath)) StartHelper();
        if (!StartXray()) { ScheduleXrayRestart(); return; }
        if (!WaitPort(Paths.SocksPort, TimeSpan.FromSeconds(8)))
        {
            Log.Write("xray не открыл порт за 8 с");
            if (xray is { } p) { xray = null; Kill(p); }
            ScheduleXrayRestart(); return;
        }
        BringUpFront();
    }

    /// Включает перехват трафика (TUN или системный прокси) поверх работающего xray.
    void BringUpFront()
    {
        switch (desired.Mode)
        {
            case ConnectionMode.Tun:
                if (singBox == null && !StartSingBox())
                {
                    ProtectAfterTunFailure(); state = TunnelState.Reconnecting; ScheduleSingBoxRestart(); return;
                }
                if (!WaitTun(TimeSpan.FromSeconds(10)))
                {
                    Log.Write("TUN не поднялся за 10 с");
                    ProtectAfterTunFailure();
                    if (singBox is { } sb) Kill(sb);   // обработчик выхода перезапустит
                    state = TunnelState.Reconnecting;
                    return;
                }
                if (proxySet) SetSystemProxy(false);
                break;
            case ConnectionMode.Proxy:
                if (singBox is { } p) { singBox = null; Kill(p); }
                if (!proxySet) SetSystemProxy(true);
                if (!proxySet) { state = TunnelState.Failed; return; }
                break;
        }
        ApplyCurrent();
        if (desired.Mode == ConnectionMode.Tun && desired.KillSwitch)
        {
            try { firewall.PermitTunnel(); }
            catch (Exception e) { failReason = e.Message; state = TunnelState.Failed; return; }
        }
        else firewall.Release();
        // «Подключено» — только после успешного запроса через сервер (как служба 2.4 на маке).
        state = TunnelState.Starting;
        tunFailStreak = 0;
        var gen = generation;
        _ = Task.Delay(1000).ContinueWith(_ => { lock (gate) if (gen == generation) CheckHealth(); });
    }

    static Dictionary<string, string> XrayEnv => new() { ["XRAY_LOCATION_ASSET"] = Paths.BinDir };

    bool StartXray()
    {
        var gen = generation;
        var p = Spawn(Paths.Xray, ["run", "-c", XrayConfigPath], XrayEnv, "xray");
        if (p == null) return false;
        xray = p;
        p.Exited += (_, _) => { lock (gate) XrayExited(p, gen); };
        return true;
    }

    bool StartSingBox()
    {
        var gen = generation;
        var p = Spawn(Paths.SingBox, ["run", "-c", SingBoxConfigPath, "-D", Paths.RunDir], null, "sing-box");
        if (p == null) return false;
        singBox = p;
        p.Exited += (_, _) => { lock (gate) SingBoxExited(p, gen); };
        return true;
    }

    void StartHelper()
    {
        var gen = generation;
        var p = Spawn(Paths.SingBox, ["run", "-c", HelperConfigPath, "-D", Paths.RunDir], null, "tuic/hy2");
        if (p == null) return;
        helper = p;
        p.Exited += (_, _) =>
        {
            lock (gate)
            {
                if (gen != generation || helper != p || !desired.Active) return;
                helper = null; restarts++;
                Log.Write($"Вспомогательное ядро завершилось (код {SafeExit(p)}), перезапуск через 2 с");
                _ = Task.Delay(2000).ContinueWith(_ => { lock (gate) if (gen == generation && helper == null && desired.Active) StartHelper(); });
            }
        };
    }

    void XrayExited(Process p, int gen)
    {
        if (gen != generation || xray != p || !desired.Active) return;
        xray = null; restarts++;
        Log.Write($"xray завершился (код {SafeExit(p)}), перезапуск");
        ScheduleXrayRestart();
    }

    void SingBoxExited(Process p, int gen)
    {
        if (gen != generation || singBox != p || !desired.Active || desired.Mode != ConnectionMode.Tun) return;
        singBox = null;
        ProtectAfterTunFailure();
        restarts++;
        Log.Write($"sing-box завершился (код {SafeExit(p)}), перезапуск через 2 с");
        // Ни разу не поднявшийся туннель (адрес занят другим VPN и т.п.) не держим вечно с закрытым интернетом.
        if (since == null && ++tunFailStreak >= 4)
        {
            failReason = "Туннель не поднимается — скорее всего, включён другой VPN. Выключите его и подключитесь снова.";
            Log.Write(failReason);
            StopProcesses();
            state = TunnelState.Failed;
            return;
        }
        state = TunnelState.Reconnecting;
        ScheduleSingBoxRestart();
    }

    void ScheduleSingBoxRestart()
    {
        var gen = generation;
        _ = Task.Delay(2000).ContinueWith(_ =>
        {
            lock (gate)
            {
                if (gen != generation || !desired.Active || singBox != null || xray == null) return;
                BringUpFront();
            }
        });
    }

    void ScheduleXrayRestart()
    {
        xrayFailStreak++;
        // Ядро ни разу не поднялось с этим конфигом — не держим пользователя без интернета бесконечно.
        if (since == null && xrayFailStreak >= 4)
        {
            failReason = "Ядро xray не запускается с этим подключением — подробности в журнале службы.";
            Log.Write(failReason);
            StopProcesses();
            state = TunnelState.Failed;
            return;
        }
        state = TunnelState.Reconnecting;
        // Без аварийной блокировки отпускаем трафик напрямую, пока ядро не поднимется.
        if (!desired.KillSwitch)
        {
            if (singBox is { } sb) { singBox = null; Kill(sb); }
            if (proxySet) SetSystemProxy(false);
        }
        else ProtectAfterTunFailure();
        var delay = TimeSpan.FromSeconds(Math.Min(Math.Pow(2, Math.Min(xrayFailStreak, 5)), 30));
        var gen = generation;
        _ = Task.Delay(delay).ContinueWith(_ =>
        {
            lock (gate)
            {
                if (gen != generation || !desired.Active || xray != null) return;
                if (!StartXray() || !WaitPort(Paths.SocksPort, TimeSpan.FromSeconds(8)))
                {
                    if (xray is { } p) { xray = null; Kill(p); }
                    ScheduleXrayRestart(); return;
                }
                BringUpFront();
            }
        });
    }

    void StopProcesses()
    {
        generation++;
        foreach (var p in new[] { singBox, xray, helper })
        {
            if (p == null) continue;
            Kill(p);
            try { p.WaitForExit(4000); } catch { }
        }
        singBox = null; xray = null; helper = null;
        SetSystemProxy(false);
        healthy = null; latencyMs = null;
    }

    /// Ядра, оставшиеся от прошлого запуска службы (обычно их снимает объект задания).
    void KillStrays()
    {
        foreach (var name in new[] { "xray", "sing-box" })
            foreach (var p in Process.GetProcessesByName(name))
            {
                try
                {
                    if (p.MainModule?.FileName is { } f && f.StartsWith(Paths.BinDir, StringComparison.OrdinalIgnoreCase)) p.Kill();
                }
                catch { }
            }
    }

    void ProtectAfterTunFailure()
    {
        if (!desired.Active || desired.Mode != ConnectionMode.Tun || !desired.KillSwitch) return;
        try { firewall.Block(desired.ExcludedRoutes); }
        catch (Exception e) { Log.Write("Ошибка аварийной блокировки: " + e.Message); state = TunnelState.Failed; }
    }

    bool WaitTun(TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (singBox == null || singBox.HasExited) return false;
            try
            {
                if (NetworkInterface.GetAllNetworkInterfaces().Any(n => n.Name == Paths.TunName && n.OperationalStatus == OperationalStatus.Up)) return true;
            }
            catch { }
            Thread.Sleep(150);
        }
        return false;
    }

    // MARK: сон и смена сети

    DateTime lastNetworkReset = DateTime.MinValue;

    /// После сна или смены сети пересоздаём ядра и TUN (маршруты и интерфейсы могли смениться).
    /// Отключённый пользователем VPN сам не включаем.
    public void NetworkChanged(string reason)
    {
        lock (gate)
        {
            if (!desired.Active) return;
            if (DateTime.UtcNow - lastNetworkReset < TimeSpan.FromSeconds(10)) return;
            lastNetworkReset = DateTime.UtcNow;
            Log.Write($"{reason} — пересоздаю подключение");
            ProtectAfterTunFailure();
            StopProcesses();
            since = null; restarts++;
            xrayFailStreak = 0; tunFailStreak = 0; healthFailStreak = 0;
            Launch();
        }
    }

    // MARK: проверка связи

    int HealthInterval => Math.Max(10, desired.Selector?.IntervalSec ?? 30);
    int FailLimit => Math.Max(2, desired.Selector?.FailLimit ?? 3);
    bool Balanced => (desired.Selector?.Candidates ?? 1) > 1;

    void StartHealthTimer()
    {
        healthTimer?.Dispose();
        var i = TimeSpan.FromSeconds(HealthInterval);
        healthTimer = new Timer(_ => { lock (gate) CheckHealth(); }, null, i, i);
    }

    /// Запрос через xray (через текущий сервер) к тестовому адресу. FailLimit неудач подряд:
    /// есть другие серверы — переход на самый быстрый из отвечающих; нет или никто не отвечает — перезапуск xray
    /// (помогает после сна и смены сети). Пока текущий отвечает, сервер не меняется.
    long probeSerial;
    void CheckHealth()
    {
        if (!desired.Active || xray == null || state is not (TunnelState.Running or TunnelState.Reconnecting or TunnelState.Starting)) return;
        if (state == TunnelState.Starting && singBox == null && desired.Mode == ConnectionMode.Tun) return;
        var gen = generation;
        var probe = ++probeSerial;
        var process = xray;
        var testURL = desired.Selector?.TestURL ?? "https://www.gstatic.com/generate_204";
        var timeout = Math.Clamp(desired.Selector?.TimeoutSec ?? 10, 2, 30);
        Task.Run(async () =>
        {
            var ms = await Probe(Paths.SocksPort, testURL, timeout);
            lock (gate)
            {
                if (gen != generation || process != xray || probe != probeSerial) return;
                var ok = ms >= 0;
                healthy = ok; latencyMs = ok ? ms : null;
                if (ok)
                {
                    healthFailStreak = 0; xrayFailStreak = 0;
                    if (state is TunnelState.Reconnecting or TunnelState.Starting) state = TunnelState.Running;
                    since ??= DateTimeOffset.Now;
                }
                else
                {
                    healthFailStreak++;
                    Log.Write($"Проверка связи не прошла ({healthFailStreak})");
                    // Пока подключение не подтверждено, проверяем чаще, а не раз в 30 с.
                    if (state == TunnelState.Starting && healthFailStreak < FailLimit)
                        _ = Task.Delay(3000).ContinueWith(_ => { lock (gate) if (gen == generation) CheckHealth(); });
                    if (healthFailStreak >= FailLimit)
                    {
                        healthFailStreak = 0;
                        if (Balanced) SwitchToAlive(); else RestartXray();
                    }
                }
            }
        });
    }

    static HttpClient MakeHttp(int? socksPort, TimeSpan timeout)
    {
        var h = new SocketsHttpHandler { PooledConnectionLifetime = TimeSpan.Zero, UseCookies = false };
        if (socksPort is { } port) { h.Proxy = new WebProxy($"socks5://127.0.0.1:{port}"); h.UseProxy = true; }
        else h.UseProxy = false;
        return new HttpClient(h) { Timeout = timeout };
    }

    /// Время ответа через локальный socks-порт, мс; -1 — нет ответа.
    static async Task<int> Probe(int port, string url, int timeoutSec)
    {
        try
        {
            using var http = MakeHttp(port, TimeSpan.FromSeconds(timeoutSec));
            var sw = Stopwatch.StartNew();
            using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead);
            return (int)resp.StatusCode is >= 200 and < 400 ? (int)sw.ElapsedMilliseconds : -1;
        }
        catch { return -1; }
    }

    void RestartXray()
    {
        if (xray is not { } p) return;
        Log.Write($"Связи нет {FailLimit} проверки подряд — перезапускаю xray");
        Kill(p);   // обработчик выхода перезапустит
    }

    /// Говорит xray, через какой сервер идти (переопределение балансировщика «auto»).
    void ApplyCurrent()
    {
        if (!Balanced || desired.Current is not { } tag) return;
        var (c, o) = RunSync(Paths.Xray, ["api", "bo", $"--server=127.0.0.1:{Paths.ApiPort}", "-b", "auto", tag]);
        if (c != 0) Log.Write($"Не выбрать сервер {tag}: " + LastLines(o, 1));
    }

    /// Текущий сервер не отвечает: замеряем остальных через пробные входы и берём самого быстрого из ответивших.
    void SwitchToAlive()
    {
        if (desired.Selector is not { } sel || xray == null) return;
        var cur = desired.Current ?? "p0";
        var gen = generation;
        Log.Write($"Сервер {cur} не отвечает {FailLimit} проверки подряд — ищу рабочий");
        Task.Run(async () =>
        {
            var tasks = Enumerable.Range(0, sel.Candidates).Where(i => $"p{i}" != cur)
                .Select(async i => ($"p{i}", await Probe(Paths.ProbeBasePort + i, sel.TestURL, Math.Max(2, sel.TimeoutSec)))).ToList();
            var res = (await Task.WhenAll(tasks)).Where(r => r.Item2 >= 0).ToList();
            lock (gate)
            {
                if (gen != generation || !desired.Active) return;
                if (res.Count == 0) { Log.Write("Ни один сервер из списка не ответил"); RestartXray(); return; }
                var best = res.MinBy(r => r.Item2);
                desired.Current = best.Item1; SaveDesired();
                ApplyCurrent();
                statsCache.at = DateTime.MinValue;
                Log.Write($"Переключился на {best.Item1} ({best.Item2} мс)");
                _ = Task.Delay(1000).ContinueWith(_ => { lock (gate) if (gen == generation) CheckHealth(); });
            }
        });
    }

    // MARK: системный прокси

    void SetSystemProxy(bool on)
    {
        if (!on && !proxySet && !File.Exists(Path.Combine(Paths.RunDir, "system-proxy.json"))) return;
        try
        {
            if (on) systemProxy.Enable(); else systemProxy.Restore();
            proxySet = on;
            Log.Write(on ? "Системный прокси включён" : "Прежний системный прокси восстановлен");
        }
        catch (Exception e)
        {
            Log.Write("Системный прокси: " + e.Message);
            state = TunnelState.Failed;
        }
    }

    // MARK: состояние

    DaemonStatus Status()
    {
        var s = new DaemonStatus
        {
            GeoUpdate = geoProgress,
            Revision = revision,
            State = state,
            Mode = desired.Active ? desired.Mode : null,
            ServerLabel = desired.Active ? desired.ServerLabel : null,
            Since = since, Restarts = restarts, Healthy = healthy, LatencyMs = latencyMs,
            KillSwitch = desired.KillSwitch, EmergencyBlock = firewall.Blocking,
            ProxyGeneration = systemProxy.Generation,
            Info = state == TunnelState.Failed ? failReason : null,
            Log = Log.Tail(120),
        };
        if (xray != null && state is TunnelState.Running or TunnelState.Reconnecting or TunnelState.Starting)
        {
            var (up, down, active) = Stats();
            s.Uplink = up; s.Downlink = down; s.ActiveOutbound = Balanced ? desired.Current : active;
        }
        return s;
    }

    (long, long, string?) Stats()
    {
        if (DateTime.UtcNow - statsCache.at < TimeSpan.FromMilliseconds(800)) return (statsCache.up, statsCache.down, statsCache.active);
        var api = $"--server=127.0.0.1:{Paths.ApiPort}";
        long up = 0, down = 0;
        var (c, o) = RunSync(Paths.Xray, ["api", "statsquery", api, "-pattern", "outbound>>>"], timeoutMs: 3000);
        if (c == 0 && Json.ParseObject(o)?.Arr("stat") is { } stats)
        {
            foreach (var st in stats.OfType<JsonObject>())
            {
                var parts = (st.Str("name") ?? "").Split(">>>");
                if (parts.Length != 4 || !parts[1].StartsWith('p')) continue;
                long.TryParse(st.Str("value"), out var v);
                if (parts[3] == "uplink") up += v; else down += v;
            }
        }
        string? active = null;
        // Ответ: «- Selects: 1 p8» — берём первый выбранный после «Selects».
        var (c2, o2) = RunSync(Paths.Xray, ["api", "bi", api, "auto"], timeoutMs: 3000);
        if (c2 == 0)
        {
            var i = o2.IndexOf("Selects:", StringComparison.Ordinal);
            if (i >= 0 && Regex.Match(o2[i..], @"\bp\d+\b") is { Success: true } m) active = m.Value;
        }
        statsCache = (DateTime.UtcNow, up, down, active);
        return (up, down, active);
    }

    DaemonStatus Fail(string msg)
    {
        Log.Write(msg);
        var s = Status(); s.Ok = false; s.Error = msg;
        return s;
    }

    // MARK: помощники

    void SaveDesired()
    {
        try { File.WriteAllText(Paths.DaemonState, Json.Serialize(desired)); } catch { }
    }

    static void WriteFile(string path, string text) => File.WriteAllText(path, text, new UTF8Encoding(false));

    static void Replace(string from, string to)
    {
        try { File.Move(from, to, overwrite: true); } catch (Exception e) { Log.Write($"Не заменить {Path.GetFileName(to)}: {e.Message}"); }
    }

    static void TryDelete(string path) { try { File.Delete(path); } catch { } }

    bool WaitPort(int port, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (TcpOpen(port)) return true;
            if (xray == null || xray.HasExited) return false;
            Thread.Sleep(100);
        }
        return false;
    }

    public static bool TcpOpen(int port)
    {
        try
        {
            using var s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            var r = s.BeginConnect(IPAddress.Loopback, port, null, null);
            var ok = r.AsyncWaitHandle.WaitOne(300) && s.Connected;
            return ok;
        }
        catch { return false; }
    }

    static Process? Spawn(string exe, string[] args, Dictionary<string, string>? env, string tag)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            WorkingDirectory = Paths.RunDir, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        if (env != null) foreach (var (k, v) in env) psi.Environment[k] = v;
        try
        {
            var p = new Process { StartInfo = psi, EnableRaisingEvents = true };
            p.OutputDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Write($"[{tag}] {e.Data}"); };
            p.ErrorDataReceived += (_, e) => { if (!string.IsNullOrWhiteSpace(e.Data)) Log.Write($"[{tag}] {e.Data}"); };
            p.Start();
            ProcessJob.Add(p);
            p.BeginOutputReadLine(); p.BeginErrorReadLine();
            return p;
        }
        catch (Exception e) { Log.Write($"Не запустить {tag}: {e.Message}"); return null; }
    }

    static void Kill(Process p) { try { if (!p.HasExited) p.Kill(entireProcessTree: true); } catch { } }
    static int SafeExit(Process p) { try { return p.ExitCode; } catch { return -1; } }

    public static (int, string) RunSync(string exe, string[] args, Dictionary<string, string>? env = null, int timeoutMs = 60000)
    {
        var psi = new ProcessStartInfo(exe)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        if (env != null) foreach (var (k, v) in env) psi.Environment[k] = v;
        try
        {
            using var p = Process.Start(psi)!;
            var o = p.StandardOutput.ReadToEndAsync(); var e = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(timeoutMs)) { try { p.Kill(true); } catch { } return (-1, "время вышло"); }
            return (p.ExitCode, o.Result + e.Result);
        }
        catch (Exception ex) { return (-1, ex.Message); }
    }

    static string LastLines(string s, int n) =>
        string.Join(" | ", s.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0 && !l.Contains("[Warning]") && !l.Contains("[Info]")).TakeLast(n));
}
