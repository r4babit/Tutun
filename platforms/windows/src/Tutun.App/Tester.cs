using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using Tutun.Core;

namespace Tutun.App;

/// Проверка серверов «по-настоящему»: временное ядро xray (и sing-box для TUIC/Hysteria2-obfs) от имени пользователя
/// открывает свой локальный порт на каждый сервер, через который идёт запрос к тестовому адресу.
/// В режиме «Весь трафик» эти ядра идут мимо VPN (правило process_path в sing-box).
public sealed class TestHarness : IDisposable
{
    public Dictionary<string, int> Ports { get; }
    readonly List<Process> processes;
    readonly string dir;

    TestHarness(Dictionary<string, int> ports, List<Process> procs, string dir) { Ports = ports; processes = procs; this.dir = dir; }

    public void Dispose()
    {
        foreach (var p in processes) { try { if (!p.HasExited) p.Kill(true); p.WaitForExit(1000); } catch { } p.Dispose(); }
        try { Directory.Delete(dir, true); } catch { }
    }

    /// Поднимает временные ядра. Серверы, которые ядро не приняло, выкидываются.
    public static async Task<TestHarness> StartAsync(List<Server> servers, AppSettings settings, CancellationToken ct = default)
    {
        var dir = Directory.CreateTempSubdirectory("tutun-test-").FullName;
        var procs = new List<Process>();
        var handedOff = false;
        try
        {
            var list = servers.Where(s => LinkParser.RejectReason(s) == null).ToList();
            var lastError = "";
            for (int attempt = 0; attempt < 6 && list.Count > 0; attempt++)
            {
                var (xcfg, hcfg, ports) = Configs(list, settings);
                var xPath = Path.Combine(dir, "x.json");
                await File.WriteAllTextAsync(xPath, xcfg, ct);
                var (code, output) = await RunAsync(Paths.Xray, ["run", "-test", "-c", xPath]);
                if (code != 0)
                {
                    lastError = output;
                    var m = System.Text.RegularExpressions.Regex.Match(output, @"tag o(\d+)");
                    if (m.Success && int.TryParse(m.Groups[1].Value, out var i) && i < list.Count) { list.RemoveAt(i); continue; }
                    break;
                }
                if (hcfg != null)
                {
                    var hPath = Path.Combine(dir, "h.json");
                    await File.WriteAllTextAsync(hPath, hcfg, ct);
                    procs.Add(Spawn(Paths.SingBox, ["run", "-c", hPath, "-D", dir]));
                }
                procs.Add(Spawn(Paths.Xray, ["run", "-c", xPath]));
                var first = ports.Values.DefaultIfEmpty(Paths.TestBasePort).Min();
                var ready = false;
                for (int k = 0; k < 50; k++)
                {
                    ct.ThrowIfCancellationRequested();
                    if (procs.Any(p => p.HasExited)) break;
                    if (TcpOpen(first)) { ready = true; break; }
                    await Task.Delay(100, ct);
                }
                if (!ready) throw new InvalidOperationException("Ядро проверки не открыло порт");
                handedOff = true;
                return new TestHarness(ports, procs, dir);
            }
            var last = lastError.Split('\n').LastOrDefault(l => l.Trim().Length > 0 && !l.Contains("[Warning]"))?.Trim();
            throw new InvalidOperationException("Ядро проверки не запустилось: " + (last ?? "нет подходящих серверов"));
        }
        finally
        {
            if (!handedOff)
            {
                foreach (var p in procs) { try { p.Kill(true); } catch { } }
                try { Directory.Delete(dir, true); } catch { }
            }
        }
    }

    static (string, string?, Dictionary<string, int>) Configs(List<Server> servers, AppSettings s)
    {
        var inbounds = new JsonArray(); var outbounds = new JsonArray(); var rules = new JsonArray();
        var ports = new Dictionary<string, int>();
        var helperIn = new JsonArray(); var helperOut = new JsonArray(); var helperRules = new JsonArray();
        int k = 0;
        for (int i = 0; i < servers.Count; i++)
        {
            var srv = servers[i];
            var port = Paths.TestBasePort + i;
            ports[srv.Id] = port;
            inbounds.Add(new JsonObject { ["tag"] = $"t{i}", ["listen"] = "127.0.0.1", ["port"] = port, ["protocol"] = "socks", ["settings"] = new JsonObject { ["udp"] = true } });
            JsonObject ob;
            if (srv.Engine == Engine.Singbox)
            {
                ob = new JsonObject { ["protocol"] = "socks", ["settings"] = new JsonObject { ["servers"] = new JsonArray(new JsonObject { ["address"] = "127.0.0.1", ["port"] = Paths.TestHelperBase + k }) } };
                helperIn.Add(new JsonObject { ["type"] = "socks", ["tag"] = $"h{k}", ["listen"] = "127.0.0.1", ["listen_port"] = Paths.TestHelperBase + k });
                var hob = srv.Outbound; hob["tag"] = $"ho{k}"; helperOut.Add(hob);
                helperRules.Add(new JsonObject { ["inbound"] = Json.StrArray([$"h{k}"]), ["outbound"] = $"ho{k}" });
                k++;
            }
            else
            {
                ob = srv.Outbound;
                if (s.Fragment && ob.Obj("streamSettings") is { } ss && (ss.Str("network") ?? "tcp") is "tcp" or "raw" or "ws" or "grpc" or "xhttp" or "httpupgrade"
                    && (ob.Str("protocol") ?? "") is "vless" or "vmess" or "trojan" or "shadowsocks")
                {
                    var so = ss.Obj("sockopt") ?? new JsonObject(); so["dialerProxy"] = "fragment"; ss["sockopt"] = so;
                }
            }
            ob["tag"] = $"o{i}";
            outbounds.Add(ob);
            rules.Add(new JsonObject { ["inboundTag"] = Json.StrArray([$"t{i}"]), ["outboundTag"] = $"o{i}" });
        }
        if (s.Fragment)
            outbounds.Add(new JsonObject { ["tag"] = "fragment", ["protocol"] = "freedom", ["settings"] = new JsonObject { ["fragment"] = new JsonObject { ["packets"] = s.FragmentPackets, ["length"] = s.FragmentLength, ["interval"] = s.FragmentInterval } } });
        outbounds.Add(new JsonObject { ["tag"] = "direct", ["protocol"] = "freedom" });
        var x = new JsonObject { ["log"] = new JsonObject { ["loglevel"] = "error" }, ["inbounds"] = inbounds, ["outbounds"] = outbounds, ["routing"] = new JsonObject { ["rules"] = rules } };
        string? h = null;
        if (helperIn.Count > 0)
        {
            helperOut.Add(new JsonObject { ["type"] = "direct", ["tag"] = "direct" });
            h = Json.ToJSON(new JsonObject
            {
                ["log"] = new JsonObject { ["level"] = "error" }, ["inbounds"] = helperIn, ["outbounds"] = helperOut,
                ["route"] = new JsonObject { ["rules"] = helperRules, ["final"] = "direct", ["auto_detect_interface"] = true },
            });
        }
        return (Json.ToJSON(x), h, ports);
    }

    public static HttpClient Client(int? socksPort, TimeSpan timeout)
    {
        var h = new SocketsHttpHandler { UseCookies = false, PooledConnectionLifetime = TimeSpan.FromMinutes(1) };
        if (socksPort is { } p) { h.Proxy = new WebProxy($"socks5://127.0.0.1:{p}"); h.UseProxy = true; } else h.UseProxy = false;
        return new HttpClient(h) { Timeout = timeout };
    }

    /// Задержка запроса через сервер, мс; -1 — не ответил. Первый запрос прогревает соединение.
    public static async Task<int> DelayAsync(int port, string url, bool head, TimeSpan timeout)
    {
        try
        {
            using var http = Client(port, timeout);
            var method = head ? HttpMethod.Head : HttpMethod.Get;
            using (var warm = await http.SendAsync(new HttpRequestMessage(method, url), HttpCompletionOption.ResponseHeadersRead)) { }
            var sw = Stopwatch.StartNew();
            using var resp = await http.SendAsync(new HttpRequestMessage(method, url), HttpCompletionOption.ResponseHeadersRead);
            return (int)resp.StatusCode < 500 ? (int)sw.ElapsedMilliseconds : -1;
        }
        catch { return -1; }
    }

    /// Скорость скачивания через сервер, байт/с.
    public static async Task<double?> SpeedAsync(int port, double seconds = 12)
    {
        try
        {
            using var http = Client(port, TimeSpan.FromSeconds(seconds + 10));
            var sw = Stopwatch.StartNew();
            using var resp = await http.GetAsync("https://speed.cloudflare.com/__down?bytes=50000000", HttpCompletionOption.ResponseHeadersRead);
            if (!resp.IsSuccessStatusCode) return null;
            await using var s = await resp.Content.ReadAsStreamAsync();
            var buf = new byte[65536]; long total = 0;
            while (sw.Elapsed.TotalSeconds < seconds)
            {
                var n = await s.ReadAsync(buf);
                if (n == 0) break;
                total += n;
            }
            return total > 0 ? total / sw.Elapsed.TotalSeconds : null;
        }
        catch { return null; }
    }

    /// Время TCP-соединения с сервером, мс; -1 — недоступен.
    public static async Task<int> TcpPingAsync(string host, int port, int timeoutMs = 3000)
    {
        try
        {
            using var c = new TcpClient();
            var sw = Stopwatch.StartNew();
            using var cts = new CancellationTokenSource(timeoutMs);
            await c.ConnectAsync(host, port, cts.Token);
            return (int)sw.ElapsedMilliseconds;
        }
        catch { return -1; }
    }

    static Process Spawn(string exe, string[] args)
    {
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = false, RedirectStandardError = false };
        foreach (var a in args) psi.ArgumentList.Add(a);
        return Process.Start(psi) ?? throw new InvalidOperationException("Не запустить " + Path.GetFileName(exe));
    }

    static async Task<(int, string)> RunAsync(string exe, string[] args)
    {
        var psi = new ProcessStartInfo(exe) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8 };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["XRAY_LOCATION_ASSET"] = Paths.BinDir;
        using var p = Process.Start(psi)!;
        var o = p.StandardOutput.ReadToEndAsync(); var e = p.StandardError.ReadToEndAsync();
        await p.WaitForExitAsync();
        return (p.ExitCode, await o + await e);
    }

    static bool TcpOpen(int port)
    {
        try
        {
            using var s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
            var r = s.BeginConnect(IPAddress.Loopback, port, null, null);
            return r.AsyncWaitHandle.WaitOne(200) && s.Connected;
        }
        catch { return false; }
    }
}
