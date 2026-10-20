using System.Runtime.InteropServices;

namespace LocalKeys.Net;

/// <summary>
/// Advertises "_localkeys._tcp" via the Windows built-in DNS-SD API (dnsapi.dll, Windows 10 1809+),
/// so the iPad finds the PC automatically — no IP addresses to type.
/// One registration per physical LAN interface, each with that interface's own address,
/// so VPN / Hyper-V / WSL adapters never end up in the advertisement.
/// </summary>
internal sealed class MdnsAdvertiser : IDisposable
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DNS_SERVICE_REGISTER_REQUEST
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr pServiceInstance;
        public IntPtr pRegisterCompletionCallback;
        public IntPtr pQueryContext;
        public IntPtr hCredentials;
        public int unicastEnabled;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void RegisterComplete(uint status, IntPtr context, IntPtr instance);

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DnsServiceConstructInstance(string pServiceName, string pHostName,
        IntPtr pIp4, IntPtr pIp6, ushort wPort, ushort wPriority, ushort wWeight,
        uint dwPropertiesCount, string[] keys, string[] values);

    [DllImport("dnsapi.dll")]
    private static extern uint DnsServiceRegister(IntPtr pRequest, IntPtr pCancel);

    [DllImport("dnsapi.dll")]
    private static extern uint DnsServiceDeRegister(IntPtr pRequest, IntPtr pCancel);

    [DllImport("dnsapi.dll")]
    private static extern void DnsServiceFreeInstance(IntPtr pInstance);

    private const uint DNS_REQUEST_PENDING = 9506;

    private static readonly RegisterComplete Callback = OnComplete;
    private static readonly IntPtr CallbackPtr = Marshal.GetFunctionPointerForDelegate(Callback);

    private readonly int _port;
    private readonly object _gate = new();
    private readonly List<IntPtr> _requests = new();

    public bool Registered { get; private set; }
    public string Advertised { get; private set; } = "";

    public MdnsAdvertiser(int port) => _port = port;

    private static void OnComplete(uint status, IntPtr context, IntPtr instance)
    {
        if (status != 0) Log.Warn($"mDNS registration completed with status {status}");
        if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance);
    }

    public void Start()
    {
        lock (_gate)
        {
            try
            {
                var host = Environment.MachineName;
                var serviceName = $"{Sanitize(host)}.{Protocol.BonjourType}.local";
                var hostName = $"{host}.local";
                var lans = NetUtil.LanInterfaces();
                var done = new List<string>();

                if (lans.Count == 0)
                {
                    // Nothing recognisable: let Windows pick (all interfaces, its own host records).
                    if (Register(serviceName, hostName, 0, null)) done.Add("any");
                }
                foreach (var lan in lans)
                {
                    if (Register(serviceName, hostName, (uint)lan.Index, lan.Address.GetAddressBytes()))
                        done.Add($"{lan.Name}={lan.Address}");
                }
                Registered = done.Count > 0;
                Advertised = string.Join(", ", done);
                Log.Info($"mDNS {serviceName}: {(Registered ? Advertised : "failed")}");
            }
            catch (Exception ex)
            {
                // EntryPointNotFound on very old Windows builds; the iPad can still find us by scanning / manual IP.
                Registered = false;
                Log.Error("mDNS register", ex);
            }
        }
    }

    private bool Register(string serviceName, string hostName, uint ifIndex, byte[]? ipv4)
    {
        IntPtr ip = IntPtr.Zero;
        if (ipv4 != null)
        {
            ip = Marshal.AllocHGlobal(4);
            Marshal.Copy(ipv4, 0, ip, 4);
        }
        var instance = DnsServiceConstructInstance(serviceName, hostName, ip, IntPtr.Zero,
            (ushort)_port, 0, 0, 1, new[] { "v" }, new[] { Protocol.Version.ToString() });
        if (instance == IntPtr.Zero) return false;

        var req = new DNS_SERVICE_REGISTER_REQUEST
        {
            Version = 1,
            InterfaceIndex = ifIndex,
            pServiceInstance = instance,
            pRegisterCompletionCallback = CallbackPtr,
        };
        var mem = Marshal.AllocHGlobal(Marshal.SizeOf<DNS_SERVICE_REGISTER_REQUEST>());
        Marshal.StructureToPtr(req, mem, false);
        uint r = DnsServiceRegister(mem, IntPtr.Zero);
        if (r != DNS_REQUEST_PENDING)
        {
            Log.Warn($"DnsServiceRegister(if={ifIndex}) -> {r}");
            return false;
        }
        _requests.Add(mem);
        return true;
    }

    private void StopInternal()
    {
        foreach (var req in _requests)
        {
            try { DnsServiceDeRegister(req, IntPtr.Zero); } catch { }
        }
        // Request/instance memory is intentionally not freed: the API may still reference it
        // asynchronously, and it is a few hundred bytes per network change.
        _requests.Clear();
        Registered = false;
    }

    public void Restart()
    {
        lock (_gate) StopInternal();
        Thread.Sleep(500);
        Start();
    }

    private static string Sanitize(string s) => new(s.Where(c => c != '.' && c != '\\').ToArray());

    public void Dispose()
    {
        lock (_gate) StopInternal();
    }
}
