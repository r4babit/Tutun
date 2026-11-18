using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Net;
using System.Net.Sockets;
using Tutun.Core;

namespace Tutun.Service;

/// Аварийная блокировка через Windows Filtering Platform после обнаружения потери TUN.
/// Фильтры живут в динамическом сеансе WFP: закрытие сеанса (или гибель службы) снимает их сами,
/// поэтому «застрявшей» блокировки после сбоя не бывает. Обратная сторона: пока служба лежит,
/// трафик не блокируется. Короткое окно между падением TUN и его обнаружением тоже не защищено.
public sealed class EmergencyFirewall : IDisposable
{
    IntPtr engine = IntPtr.Zero;
    long? permittedLuid;
    readonly List<ulong> tunFilters = [];
    public bool Blocking => engine != IntPtr.Zero;

    static readonly Guid SubLayerKey = new("6f1c3a52-6a3e-4d3c-9a77-7475747501aa");
    static readonly Guid LayerConnectV4 = new("c38d57d1-05a7-4c33-904f-7fbceee60e82");
    static readonly Guid LayerConnectV6 = new("4a72393b-319f-44bc-84c3-ba54dcb3b6b4");
    static readonly Guid LayerRecvV4 = new("e1cd9fe7-f4b5-4273-96c0-592e487b8650");
    static readonly Guid LayerRecvV6 = new("a3b42c97-9f04-4672-b87e-cee9c483257f");
    static readonly Guid ConditionFlags = new("632ce23b-5167-435c-86d7-e903684aa80c");

    const uint FWP_ACTION_BLOCK = 0x1001, FWP_ACTION_PERMIT = 0x1002;
    const uint FWP_UINT8 = 1, FWP_UINT32 = 3;
    const uint FWP_MATCH_FLAGS_ALL_SET = 6;   // FWP_MATCH_TYPE: EQUAL=0 … RANGE=5, FLAGS_ALL_SET=6, FLAGS_ANY_SET=7, FLAGS_NONE_SET=8
    const uint FWP_CONDITION_FLAG_IS_LOOPBACK = 0x1;
    const uint FWPM_SESSION_FLAG_DYNAMIC = 0x1;
    const uint RPC_C_AUTHN_WINNT = 10;

    /// Заблокировать весь трафик, кроме петли 127.0.0.1/::1. Повторный вызов ничего не делает.
    public void Block(IEnumerable<string>? excluded = null)
    {
        if (Blocking) return;
        var session = new FWPM_SESSION0 { flags = FWPM_SESSION_FLAG_DYNAMIC, txnWaitTimeoutInMSec = 5000 };
        Check(FwpmEngineOpen0(null, RPC_C_AUTHN_WINNT, IntPtr.Zero, ref session, out var h), "открыть WFP");
        try
        {
            Check(FwpmTransactionBegin0(h, 0), "начать транзакцию WFP");
            var name = Marshal.StringToHGlobalUni("Tutun emergency block");
            try
            {
                var sub = new FWPM_SUBLAYER0 { subLayerKey = SubLayerKey, displayData = new FWPM_DISPLAY_DATA0 { name = name }, weight = 0xFFFF };
                Check(FwpmSubLayerAdd0(h, ref sub, IntPtr.Zero), "добавить подуровень WFP");
                foreach (var layer in new[] { LayerConnectV4, LayerConnectV6, LayerRecvV4, LayerRecvV6 })
                {
                    AddFilter(h, layer, name, loopbackPermit: true);
                    foreach (var exe in new[] { Paths.Xray, Paths.SingBox })
                    {
                        Check(FwpmGetAppIdFromFileName0(exe, out var app), "путь ядра WFP");
                        try { Permit(h, layer, name, new Guid("d78e1e87-8644-4ea5-9437-d809ecefc971"), 12, app); }
                        finally { FwpmFreeMemory0(ref app); }
                    }
                    foreach (var cidr in (excluded ?? []).Concat(["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16", "fe80::/10", "fc00::/7"]).Distinct())
                        PermitNetwork(h, layer, name, cidr);
                    AddFilter(h, layer, name, loopbackPermit: false);
                }
            }
            finally { Marshal.FreeHGlobal(name); }
            Check(FwpmTransactionCommit0(h), "применить фильтры WFP");
        }
        catch
        {
            FwpmTransactionAbort0(h);
            FwpmEngineClose0(h);
            throw;
        }
        engine = h;
        // Ядра общаются через 127.0.0.1. Если фильтр задел и петлю, служба зациклится с закрытым интернетом —
        // поэтому сразу проверяем и при отказе снимаем блокировку (дескриптор закрывается один раз, в Release).
        if (!LoopbackWorks())
        {
            Release();
            throw new InvalidOperationException("Аварийная блокировка перекрыла внутренние соединения 127.0.0.1 и отключена");
        }
        Log.Write("Аварийная блокировка WFP включена");
    }

    /// Снять блокировку: закрытие динамического сеанса удаляет все его фильтры.
    public void Release()
    {
        if (!Blocking) return;
        FwpmEngineClose0(engine);
        engine = IntPtr.Zero;
        permittedLuid = null;
        tunFilters.Clear();
        Log.Write("Аварийная блокировка WFP снята");
    }

    public void Dispose() => Release();

    // Add an exception only for the current Tutun interface. WFP compares the full NET_LUID.
    public void PermitTunnel()
    {
        if (!Blocking) return;
        Check(ConvertInterfaceAliasToLuid(Paths.TunName, out var luid), "интерфейс TUN");
        if (luid == permittedLuid) return;
        var value = Marshal.AllocHGlobal(8);
        var name = Marshal.StringToHGlobalUni("Tutun tunnel interface");
        try
        {
            Marshal.WriteInt64(value, luid);
            Check(FwpmTransactionBegin0(engine, 0), "транзакция TUN");
            try
            {
                foreach (var id in tunFilters) Check(FwpmFilterDeleteById0(engine, id), "удалить прежнее правило TUN");
                var filters = new List<ulong>();
                foreach (var layer in new[] { LayerConnectV4, LayerConnectV6, LayerRecvV4, LayerRecvV6 })
                    filters.Add(Permit(engine, layer, name, new Guid("4cd62a49-59c3-4969-b7f3-bda5d32890a4"), 4, value));
                Check(FwpmTransactionCommit0(engine), "установить правила TUN");
                tunFilters.Clear();
                tunFilters.AddRange(filters);
                permittedLuid = luid;
            }
            catch { FwpmTransactionAbort0(engine); throw; }
        }
        finally { Marshal.FreeHGlobal(name); Marshal.FreeHGlobal(value); }
    }

    static void PermitNetwork(IntPtr h, Guid layer, IntPtr name, string cidr)
    {
        if (!System.Net.IPNetwork.TryParse(cidr, out var network))
        {
            if (!IPAddress.TryParse(cidr, out var ip)) throw new InvalidDataException("Неверная подсеть: " + cidr);
            network = new(ip, ip.AddressFamily == AddressFamily.InterNetwork ? 32 : 128);
        }
        var bytes = network.BaseAddress.GetAddressBytes();
        var v4 = bytes.Length == 4;
        if (v4 != (layer == LayerConnectV4 || layer == LayerRecvV4)) return;
        var address = Marshal.AllocHGlobal(20);
        try
        {
            if (v4)
            {
                Marshal.WriteInt32(address, System.Buffers.Binary.BinaryPrimitives.ReadInt32BigEndian(bytes));
                Marshal.WriteInt32(address, 4, network.PrefixLength == 0 ? 0 : -1 << (32 - network.PrefixLength));
            }
            else
            {
                Marshal.Copy(bytes, 0, address, 16);
                Marshal.WriteByte(address, 16, (byte)network.PrefixLength);
            }
            Permit(h, layer, name, new Guid("b235ae9a-1d64-49b8-a44c-5ff3d9095045"), v4 ? 256u : 257u, address);
        }
        finally { Marshal.FreeHGlobal(address); }
    }

    static ulong Permit(IntPtr h, Guid layer, IntPtr name, Guid field, uint type, IntPtr value)
    {
        var ptr = Marshal.AllocHGlobal(Marshal.SizeOf<FWPM_FILTER_CONDITION0>());
        try
        {
            Marshal.StructureToPtr(new FWPM_FILTER_CONDITION0 { fieldKey = field,
                conditionValue = new FWP_VALUE0 { type = type, value = (ulong)value.ToInt64() } }, ptr, false);
            var filter = new FWPM_FILTER0 { filterKey = Guid.NewGuid(), layerKey = layer, subLayerKey = SubLayerKey,
                displayData = new FWPM_DISPLAY_DATA0 { name = name }, numFilterConditions = 1, filterCondition = ptr,
                weight = new FWP_VALUE0 { type = FWP_UINT8, value = 14 }, action = new FWPM_ACTION0 { type = FWP_ACTION_PERMIT } };
            Check(FwpmFilterAdd0(h, ref filter, IntPtr.Zero, out var id), "исключение WFP");
            return id;
        }
        finally { Marshal.FreeHGlobal(ptr); }
    }

    [DllImport("iphlpapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] static extern uint ConvertInterfaceAliasToLuid(string alias, out long luid);
    [DllImport("fwpuclnt.dll", CharSet = CharSet.Unicode, ExactSpelling = true)] static extern uint FwpmGetAppIdFromFileName0(string file, out IntPtr app);
    [DllImport("fwpuclnt.dll")] static extern void FwpmFreeMemory0(ref IntPtr pointer);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterDeleteById0(IntPtr handle, ulong id);

    static bool LoopbackWorks()
    {
        try
        {
            var l = new System.Net.Sockets.TcpListener(System.Net.IPAddress.Loopback, 0);
            l.Start();
            try
            {
                var port = ((System.Net.IPEndPoint)l.LocalEndpoint).Port;
                using var c = new System.Net.Sockets.TcpClient();
                var ok = c.ConnectAsync(System.Net.IPAddress.Loopback, port).Wait(1500) && c.Connected;
                return ok;
            }
            finally { l.Stop(); }
        }
        catch { return false; }
    }

    static void AddFilter(IntPtr h, Guid layer, IntPtr name, bool loopbackPermit)
    {
        var filter = new FWPM_FILTER0
        {
            filterKey = Guid.NewGuid(),
            displayData = new FWPM_DISPLAY_DATA0 { name = name },
            layerKey = layer,
            subLayerKey = SubLayerKey,
            weight = new FWP_VALUE0 { type = FWP_UINT8, value = (ulong)(loopbackPermit ? 15 : 0) },
            action = new FWPM_ACTION0 { type = loopbackPermit ? FWP_ACTION_PERMIT : FWP_ACTION_BLOCK },
        };
        IntPtr cond = IntPtr.Zero;
        try
        {
            if (loopbackPermit)
            {
                var c = new FWPM_FILTER_CONDITION0
                {
                    fieldKey = ConditionFlags, matchType = FWP_MATCH_FLAGS_ALL_SET,
                    conditionValue = new FWP_VALUE0 { type = FWP_UINT32, value = FWP_CONDITION_FLAG_IS_LOOPBACK },
                };
                cond = Marshal.AllocHGlobal(Marshal.SizeOf<FWPM_FILTER_CONDITION0>());
                Marshal.StructureToPtr(c, cond, false);
                filter.numFilterConditions = 1;
                filter.filterCondition = cond;
            }
            Check(FwpmFilterAdd0(h, ref filter, IntPtr.Zero, out _), "добавить фильтр WFP");
        }
        finally { if (cond != IntPtr.Zero) Marshal.FreeHGlobal(cond); }
    }

    static void Check(uint rc, string what)
    {
        if (rc != 0) throw new InvalidOperationException($"Аварийная блокировка: не удалось {what} (0x{rc:X8}: {new Win32Exception((int)rc).Message})");
    }

    // Структуры fwpmtypes.h (x64). Объединения представлены полем максимального размера.

    [StructLayout(LayoutKind.Sequential)]
    struct FWPM_DISPLAY_DATA0 { public IntPtr name; public IntPtr description; }

    [StructLayout(LayoutKind.Sequential)]
    struct FWP_BYTE_BLOB { public uint size; public IntPtr data; }

    [StructLayout(LayoutKind.Sequential)]
    struct FWP_VALUE0 { public uint type; public ulong value; }

    [StructLayout(LayoutKind.Sequential)]
    struct FWPM_SESSION0
    {
        public Guid sessionKey;
        public FWPM_DISPLAY_DATA0 displayData;
        public uint flags;
        public uint txnWaitTimeoutInMSec;
        public uint processId;
        public IntPtr sid;
        public IntPtr username;
        public int kernelMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FWPM_SUBLAYER0
    {
        public Guid subLayerKey;
        public FWPM_DISPLAY_DATA0 displayData;
        public uint flags;
        public IntPtr providerKey;
        public FWP_BYTE_BLOB providerData;
        public ushort weight;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FWPM_FILTER_CONDITION0
    {
        public Guid fieldKey;
        public uint matchType;
        public FWP_VALUE0 conditionValue;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct FWPM_ACTION0 { public uint type; public Guid filterType; }

    [StructLayout(LayoutKind.Sequential)]
    struct FWPM_FILTER0
    {
        public Guid filterKey;
        public FWPM_DISPLAY_DATA0 displayData;
        public uint flags;
        public IntPtr providerKey;
        public FWP_BYTE_BLOB providerData;
        public Guid layerKey;
        public Guid subLayerKey;
        public FWP_VALUE0 weight;
        public uint numFilterConditions;
        public IntPtr filterCondition;
        public FWPM_ACTION0 action;
        public ulong providerContext0;    // объединение rawContext / providerContextKey: 16 байт, выравнивание 8
        public ulong providerContext1;
        public IntPtr reserved;
        public ulong filterId;
        public FWP_VALUE0 effectiveWeight;
    }

    [DllImport("fwpuclnt.dll", CharSet = CharSet.Unicode)]
    static extern uint FwpmEngineOpen0(string? serverName, uint authnService, IntPtr authIdentity, ref FWPM_SESSION0 session, out IntPtr engineHandle);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmEngineClose0(IntPtr engineHandle);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionBegin0(IntPtr engineHandle, uint flags);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionCommit0(IntPtr engineHandle);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmTransactionAbort0(IntPtr engineHandle);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmSubLayerAdd0(IntPtr engineHandle, ref FWPM_SUBLAYER0 subLayer, IntPtr sd);
    [DllImport("fwpuclnt.dll")] static extern uint FwpmFilterAdd0(IntPtr engineHandle, ref FWPM_FILTER0 filter, IntPtr sd, out ulong id);
}
