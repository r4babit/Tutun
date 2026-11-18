using System.IO.Pipes;
using System.Text;

namespace Tutun.Core;

public enum TunnelState { Stopped, Starting, Running, Reconnecting, Failed }

public enum DaemonCommand { Status, Start, Stop, Ping, UpdateGeo, WaitForChange }

/// Как служба держит связь: проверка раз в IntervalSec; FailLimit неудач подряд — сервер не отвечает.
public sealed class SelectorParams
{
    public int Candidates { get; set; }
    public int IntervalSec { get; set; }
    public int FailLimit { get; set; }
    public string TestURL { get; set; } = "";
    public int TimeoutSec { get; set; }
}

/// Запрос к службе. Сырые конфиги и пути служба не принимает — только описание подключения.
public sealed class DaemonRequest
{
    public DaemonCommand Cmd { get; set; }
    public long Revision { get; set; }
    public ConnectionInput? Connection { get; set; }
    public string? ServerLabel { get; set; }
    public string? GeoipURL { get; set; }
    public string? GeositeURL { get; set; }
}

public sealed class DaemonStatus
{
    public const string DaemonVersion = "1.12-win";

    public GeoUpdateProgress? GeoUpdate { get; set; }
    public long Revision { get; set; }

    public bool Ok { get; set; } = true;
    public string? Error { get; set; }
    public string? Info { get; set; }
    public TunnelState State { get; set; } = TunnelState.Stopped;
    public ConnectionMode? Mode { get; set; }
    public string? ServerLabel { get; set; }
    public string? ActiveOutbound { get; set; }
    public DateTimeOffset? Since { get; set; }
    public long Uplink { get; set; }
    public long Downlink { get; set; }
    public int Restarts { get; set; }
    public bool? Healthy { get; set; }
    public int? LatencyMs { get; set; }
    public bool? KillSwitch { get; set; }
    /// Фильтры WFP активны. При работающем TUN они разрешают трафик через туннель.
    public bool EmergencyBlock { get; set; }
    /// Счётчик изменений системного прокси — окно по нему обновляет настройки WinINet в сеансе пользователя.
    public int ProxyGeneration { get; set; }
    public string Version { get; set; } = DaemonVersion;
    public List<string> Log { get; set; } = new();
}

public sealed record GeoUpdateProgress(string File, string Stage, long Downloaded = 0,
    long? Total = null, string? Error = null, DateTimeOffset? CompletedAt = null);

/// Обмен со службой через именованный канал: одна строка JSON туда, одна обратно.
public static class Ipc
{
    public sealed class NotRunningException() : Exception("Служба Tutun не запущена");

    public static async Task<DaemonStatus> SendAsync(DaemonRequest request, TimeSpan timeout, CancellationToken ct = default)
    {
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        await using var pipe = new NamedPipeClientStream(".", Paths.PipeName, PipeDirection.InOut, PipeOptions.Asynchronous,
                                                         System.Security.Principal.TokenImpersonationLevel.Identification);
        try { await pipe.ConnectAsync((int)Math.Min(timeout.TotalMilliseconds, 3000), cts.Token); }
        catch (TimeoutException) { throw new NotRunningException(); }
        catch (UnauthorizedAccessException) { throw new IOException("Нет доступа к службе Tutun: она установлена для другого пользователя"); }
        var payload = Encoding.UTF8.GetBytes(Json.Serialize(request) + "\n");
        await pipe.WriteAsync(payload, cts.Token);
        await pipe.FlushAsync(cts.Token);
        var line = await ReadLineAsync(pipe, cts.Token);
        return Json.Deserialize<DaemonStatus>(line) ?? throw new IOException("Пустой ответ службы");
    }

    public static async Task<byte[]> ReadLineAsync(Stream s, CancellationToken ct, int limit = 8 << 20)
    {
        var ms = new MemoryStream();
        var buf = new byte[65536];
        while (ms.Length < limit)
        {
            var n = await s.ReadAsync(buf, ct);
            if (n == 0) break;
            var nl = Array.IndexOf(buf, (byte)'\n', 0, n);
            if (nl >= 0) { ms.Write(buf, 0, nl); return ms.ToArray(); }
            ms.Write(buf, 0, n);
        }
        if (ms.Length == 0) throw new IOException("пустой ответ");
        return ms.ToArray();
    }
}







