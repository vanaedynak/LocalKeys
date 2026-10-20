using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace LocalKeys.Net;

/// <summary>TCP listener for iPads on the local network + Bonjour/mDNS advertisement.</summary>
internal sealed class WifiServer : IDisposable
{
    private readonly AgentCore _core;
    private readonly int _port;
    private Socket? _listener;
    private Thread? _thread;
    private volatile bool _stopped;
    private readonly MdnsAdvertiser _mdns;
    private readonly System.Threading.Timer _readvertise;

    public bool Listening { get; private set; }
    public string? Error { get; private set; }

    public WifiServer(AgentCore core, int port)
    {
        _core = core;
        _port = port;
        _mdns = new MdnsAdvertiser(port);
        _readvertise = new System.Threading.Timer(_ => _mdns.Restart(), null, Timeout.Infinite, Timeout.Infinite);
    }

    public bool Advertised => _mdns.Registered;
    public string AdvertisedOn => _mdns.Advertised;

    public void Start()
    {
        _stopped = false;
        _thread = new Thread(AcceptLoop) { IsBackground = true, Name = "WifiServer" };
        _thread.Start();
        _mdns.Start();
        NetworkChange.NetworkAddressChanged += OnNetworkChanged;
    }

    private void OnNetworkChanged(object? sender, EventArgs e)
    {
        // Address changes come in bursts (DHCP, adapters waking up): re-advertise once things settle.
        _readvertise.Change(2500, Timeout.Infinite);
    }

    private void AcceptLoop()
    {
        while (!_stopped)
        {
            try
            {
                _listener = new Socket(AddressFamily.InterNetworkV6, SocketType.Stream, ProtocolType.Tcp);
                _listener.DualMode = true;
                _listener.Bind(new IPEndPoint(IPAddress.IPv6Any, _port));
                _listener.Listen(16);
                Listening = true;
                Error = null;
                Log.Info($"Wi-Fi server listening on port {_port}");
                while (!_stopped)
                {
                    var s = _listener.Accept();
                    var remote = (s.RemoteEndPoint as IPEndPoint)?.Address;
                    var remoteText = remote == null ? "?" : (remote.IsIPv4MappedToIPv6 ? remote.MapToIPv4().ToString() : remote.ToString());
                    var session = new Session(s, Transport.Wifi, _core, remoteText);
                    _core.AddSession(session);
                    session.Start();
                }
            }
            catch (Exception ex)
            {
                Listening = false;
                if (_stopped) break;
                Error = ex.Message;
                Log.Error("Wi-Fi listener", ex);
                try { _listener?.Dispose(); } catch { }
                Thread.Sleep(3000);
            }
        }
        Listening = false;
    }

    public static List<string> LocalAddresses() =>
        NetUtil.LanInterfaces().Select(i => i.Address.ToString()).Distinct().ToList();

    public void Dispose()
    {
        _stopped = true;
        _readvertise.Dispose();
        NetworkChange.NetworkAddressChanged -= OnNetworkChanged;
        try { _listener?.Dispose(); } catch { }
        _mdns.Dispose();
    }
}
