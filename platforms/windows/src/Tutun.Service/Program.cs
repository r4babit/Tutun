using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using Tutun.Core;
using Tutun.Service;

// Tutun.Service — служба Windows (LocalSystem). Держит VPN независимо от окна.
// Команды принимает по именованному каналу \\.\pipe\tutun.service только от владельца установки и SYSTEM.

var builder = Host.CreateApplicationBuilder(args);
builder.Services.AddWindowsService(o => o.ServiceName = Paths.ServiceName);
builder.Services.AddHostedService<ServiceWorker>();
builder.Logging.ClearProviders();
builder.Build().Run();

sealed class ServiceWorker : BackgroundService
{
    Supervisor? supervisor;
    SecurityIdentifier? owner;

    protected override async Task ExecuteAsync(CancellationToken stop)
    {
        Directory.CreateDirectory(Paths.DataDir);
        string ownerText;
        try { ownerText = File.ReadAllText(Paths.OwnerFile).Trim(); owner = new SecurityIdentifier(ownerText); }
        catch
        {
            Log.Write("Нет владельца установки (owner.sid). Переустановите службу через Tutun.");
            throw;
        }
        supervisor = new Supervisor(owner.Value);
        supervisor.Boot();
        StartNetworkWatch(stop);
        Log.Write($"Канал готов, владелец {owner.Value}");
        while (!stop.IsCancellationRequested)
        {
            NamedPipeServerStream pipe;
            try { pipe = CreatePipe(); }
            catch (Exception e) { Log.Write("Не создать канал: " + e.Message); await Task.Delay(1000, stop); continue; }
            try { await pipe.WaitForConnectionAsync(stop); }
            catch (OperationCanceledException) { pipe.Dispose(); break; }
            catch (Exception e) { Log.Write("Канал: " + e.Message); pipe.Dispose(); continue; }
            _ = Task.Run(() => Serve(pipe), CancellationToken.None);
        }
    }

    /// Сон и смена сети. Служба не получает оконных событий питания, поэтому сон определяем по скачку часов
    /// (таймер раз в 5 с внезапно сработал через минуту+), а смену сети — по набору физических адаптеров со шлюзом.
    void StartNetworkWatch(CancellationToken stop)
    {
        string Signature() => string.Join("|", System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.Name != Paths.TunName && n.OperationalStatus == System.Net.NetworkInformation.OperationalStatus.Up
                        && n.NetworkInterfaceType is not (System.Net.NetworkInformation.NetworkInterfaceType.Loopback or System.Net.NetworkInformation.NetworkInterfaceType.Tunnel))
            .Select(n =>
            {
                var p = n.GetIPProperties();
                var gw = p.GatewayAddresses.Select(g => g.Address.ToString()).Where(a => a != "0.0.0.0" && a != "::").ToList();
                if (gw.Count == 0) return null;
                var ip = p.UnicastAddresses.Where(a => a.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork).Select(a => a.Address.ToString());
                return n.Id + "=" + string.Join(",", ip) + ">" + string.Join(",", gw);
            })
            .OfType<string>().OrderBy(x => x));

        var last = Signature();
        var pending = 0;
        System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged += (_, _) =>
        {
            // Дребезг: адаптеры меняются пачкой; реагируем, когда всё улеглось на 3 с.
            var my = Interlocked.Increment(ref pending);
            _ = Task.Delay(3000).ContinueWith(_ =>
            {
                if (my != Volatile.Read(ref pending)) return;
                string now;
                try { now = Signature(); } catch { return; }
                if (now == last) return;
                var had = last.Length > 0; last = now;
                if (had && now.Length > 0) supervisor!.NetworkChanged("Сменилась сеть");
                else if (now.Length > 0) supervisor!.NetworkChanged("Сеть появилась");
            });
        };

        _ = Task.Run(async () =>
        {
            var tick = DateTime.UtcNow;
            while (!stop.IsCancellationRequested)
            {
                try { await Task.Delay(5000, stop); } catch { return; }
                var now = DateTime.UtcNow;
                if (now - tick > TimeSpan.FromSeconds(60)) supervisor!.NetworkChanged("Компьютер проснулся");
                tick = now;
            }
        });
    }

    NamedPipeServerStream CreatePipe()
    {
        var sec = new PipeSecurity();
        sec.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null), PipeAccessRights.FullControl, AccessControlType.Allow));
        sec.AddAccessRule(new PipeAccessRule(owner!, PipeAccessRights.ReadWrite, AccessControlType.Allow));
        // Удалённые подключения по сети запрещены явно.
        sec.AddAccessRule(new PipeAccessRule(new SecurityIdentifier(WellKnownSidType.NetworkSid, null), PipeAccessRights.FullControl, AccessControlType.Deny));
        return NamedPipeServerStreamAcl.Create(Paths.PipeName, PipeDirection.InOut, NamedPipeServerStream.MaxAllowedServerInstances,
            PipeTransmissionMode.Byte, PipeOptions.Asynchronous, 0, 0, sec);
    }

    async Task Serve(NamedPipeServerStream pipe)
    {
        await using var _ = pipe;
        DaemonStatus resp;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            var line = await Ipc.ReadLineAsync(pipe, cts.Token);
            var req = Json.Deserialize<DaemonRequest>(line) ?? throw new InvalidDataException("пусто");
            resp = await Task.Run(() => supervisor!.Handle(req));
        }
        catch (Exception e)
        {
            resp = new DaemonStatus { Ok = false, Error = "Неверный запрос: " + e.Message };
        }
        try
        {
            var data = Encoding.UTF8.GetBytes(Json.Serialize(resp) + "\n");
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await pipe.WriteAsync(data, cts.Token);
            await pipe.FlushAsync(cts.Token);
            pipe.WaitForPipeDrain();
        }
        catch { }
    }

    public override Task StopAsync(CancellationToken ct)
    {
        supervisor?.Shutdown();
        return base.StopAsync(ct);
    }
}
