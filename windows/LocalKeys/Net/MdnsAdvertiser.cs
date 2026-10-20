using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace LocalKeys.Net;

/// <summary>
/// Advertises "_localkeys._tcp" via the Windows built-in DNS-SD API (dnsapi.dll, Windows 10 1809+),
/// so the iPad finds the PC automatically — no IP addresses to type.
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
    private IntPtr _request = IntPtr.Zero;
    private IntPtr _instance = IntPtr.Zero;
    private IntPtr _ip4 = IntPtr.Zero;

    public bool Registered { get; private set; }

    public MdnsAdvertiser(int port) => _port = port;

    private static void OnComplete(uint status, IntPtr context, IntPtr instance)
    {
        if (status != 0) Log.Warn($"mDNS registration completed with status {status}");
        else Log.Info("mDNS registration complete");
        if (instance != IntPtr.Zero) DnsServiceFreeInstance(instance);
    }

    public void Start()
    {
        lock (_gate)
        {
            try
            {
                var ip = PrimaryIPv4();
                var host = Environment.MachineName;
                var serviceName = $"{Sanitize(host)}.{Protocol.BonjourType}.local";
                var hostName = $"{host}.local";

                if (ip != null)
                {
                    _ip4 = Marshal.AllocHGlobal(4);
                    Marshal.Copy(ip.GetAddressBytes(), 0, _ip4, 4);
                }

                _instance = DnsServiceConstructInstance(serviceName, hostName, _ip4, IntPtr.Zero,
                    (ushort)_port, 0, 0, 1, new[] { "v" }, new[] { Protocol.Version.ToString() });
                if (_instance == IntPtr.Zero)
                {
                    Log.Warn("DnsServiceConstructInstance failed");
                    return;
                }

                var req = new DNS_SERVICE_REGISTER_REQUEST
                {
                    Version = 1,
                    InterfaceIndex = 0,
                    pServiceInstance = _instance,
                    pRegisterCompletionCallback = CallbackPtr,
                    pQueryContext = IntPtr.Zero,
                    hCredentials = IntPtr.Zero,
                    unicastEnabled = 0,
                };
                _request = Marshal.AllocHGlobal(Marshal.SizeOf<DNS_SERVICE_REGISTER_REQUEST>());
                Marshal.StructureToPtr(req, _request, false);

                uint r = DnsServiceRegister(_request, IntPtr.Zero);
                Registered = r == DNS_REQUEST_PENDING;
                Log.Info($"mDNS register {serviceName} ip={ip} -> {r}");
            }
            catch (Exception ex)
            {
                // EntryPointNotFound on very old Windows builds; the iPad can still find us by scanning / manual IP.
                Registered = false;
                Log.Error("mDNS register", ex);
            }
        }
    }

    private void StopInternal()
    {
        try
        {
            if (_request != IntPtr.Zero && Registered)
                DnsServiceDeRegister(_request, IntPtr.Zero);
        }
        catch { }
        Registered = false;
        // The request/instance memory is intentionally leaked on re-registration: the API may still
        // reference it asynchronously and it is a few hundred bytes per network change.
        _request = IntPtr.Zero;
        _instance = IntPtr.Zero;
        _ip4 = IntPtr.Zero;
    }

    public void Restart()
    {
        lock (_gate) StopInternal();
        Thread.Sleep(500);
        Start();
    }

    private static string Sanitize(string s) => new(s.Where(c => c != '.' && c != '\\').ToArray());

    public static IPAddress? PrimaryIPv4()
    {
        try
        {
            IPAddress? fallback = null;
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                if (ni.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
                var p = ni.GetIPProperties();
                var addr = p.UnicastAddresses.FirstOrDefault(a => a.Address.AddressFamily == AddressFamily.InterNetwork
                                                                 && !a.Address.ToString().StartsWith("169.254."))?.Address;
                if (addr == null) continue;
                if (p.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any)))
                    return addr;
                fallback ??= addr;
            }
            return fallback;
        }
        catch { return null; }
    }

    public void Dispose()
    {
        lock (_gate) StopInternal();
    }
}
