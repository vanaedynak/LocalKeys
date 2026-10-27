using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using LocalKeys.Input;
using LocalKeys.Net;

namespace LocalKeys;

internal sealed class PairingRequest
{
    public required Session Session { get; init; }
    public required string DeviceId { get; init; }
    public required string DeviceName { get; init; }
    public required string Code { get; init; }
}

/// <summary>Central hub: sessions, authentication/pairing, routing input to the per-device injector.</summary>
internal sealed class AgentCore : IDisposable
{
    public Config Config { get; }
    public LayoutMonitor Layouts { get; } = new();
    public WifiServer? Wifi { get; private set; }
    public UsbMuxClient? Usb { get; private set; }
    public AdbBridge? Adb { get; private set; }
    public Updater Updater { get; }
    public VirtualJoystick Joystick { get; } = new();

    private readonly object _gate = new();
    private readonly List<Session> _sessions = new();
    private readonly Dictionary<string, DeviceInput> _devices = new();
    private readonly Dictionary<string, PairingRequest> _pendingPairing = new();

    /// <summary>Raised on a worker thread; the UI marshals it.</summary>
    public event Action<PairingRequest>? PairingRequested;
    public event Action<PairingRequest>? PairingCancelled;
    public event Action? SessionsChanged;
    public event Action<Session>? DeviceConnected;
    public event Action? ShowRequested;

    public AgentCore(Config config)
    {
        Config = config;
        Updater = new Updater(config, () => AnyDeviceConnected());
        Layouts.Changed += state => Broadcast(s => s.SendJson(Protocol.PcState, WithAddresses(state)));
        _stallTimer = new System.Threading.Timer(_ => CheckStalls(), null, 250, 250);
    }

    private readonly System.Threading.Timer _stallTimer;

    public void Start()
    {
        if (Config.WifiEnabled)
        {
            Wifi = new WifiServer(this, Config.WifiPort);
            Wifi.Start();
        }
        if (Config.UsbEnabled)
        {
            Usb = new UsbMuxClient(this);
            Usb.Start();
            if (Config.WifiEnabled)
            {
                Adb = new AdbBridge(Config.WifiPort);
                Adb.Start();
            }
        }
    }

    public List<Session> Sessions()
    {
        lock (_gate) return _sessions.ToList();
    }

    public void AddSession(Session s)
    {
        lock (_gate) _sessions.Add(s);
        s.Closed += OnSessionClosed;
        Log.Info($"Connection from {s.Remote} ({s.Transport})");
        SessionsChanged?.Invoke();
    }

    private void OnSessionClosed(Session s)
    {
        PairingRequest? cancelled = null;
        lock (_gate)
        {
            _sessions.Remove(s);
            if (s.DeviceId != null && _devices.TryGetValue(s.DeviceId, out var dev) && ReferenceEquals(dev.ActiveSession, s))
            {
                // Safety first: never leave keys stuck when the link that carried them goes away.
                dev.ReleaseAll();
                dev.ActiveSession = null;
                Joystick.Neutral(s.DeviceId);
            }
            foreach (var (k, p) in _pendingPairing.ToList())
                if (ReferenceEquals(p.Session, s)) { _pendingPairing.Remove(k); cancelled = p; }
        }
        if (cancelled != null) PairingCancelled?.Invoke(cancelled);
        if (s.Authed) Log.Info($"Disconnected {s}");
        SessionsChanged?.Invoke();
    }

    private void Broadcast(Action<Session> action)
    {
        foreach (var s in Sessions().Where(x => x.Authed)) action(s);
    }

    private DeviceInput Device(string id)
    {
        lock (_gate)
        {
            if (!_devices.TryGetValue(id, out var d))
            {
                d = new DeviceInput(id);
                _devices[id] = d;
            }
            return d;
        }
    }

    public void HandleFrame(Session s, byte type, ReadOnlySpan<byte> p)
    {
        if (s.Authed && s.DeviceId != null) Device(s.DeviceId).MarkAlive();
        if (type == Protocol.Ping)
        {
            s.Send(Protocol.Pong, p);
            return;
        }
        if (type == Protocol.Pong) return;
        if (type == Protocol.ShowUi)
        {
            if (s.IsLoopback) ShowRequested?.Invoke();
            s.Close();
            return;
        }

        if (!s.Authed)
        {
            if (type == Protocol.Hello) HandleHello(s, p);
            return;
        }

        var dev = Device(s.DeviceId!);
        switch (type)
        {
            case Protocol.KeyDown:
                if (p.Length < 2) return;
                dev.ActiveSession = s;
                dev.KeyDown(BinaryPrimitives.ReadUInt16BigEndian(p));
                break;
            case Protocol.KeyUp:
                if (p.Length < 2) return;
                dev.ActiveSession = s;
                dev.KeyUp(BinaryPrimitives.ReadUInt16BigEndian(p));
                break;
            case Protocol.MouseMove:
                if (p.Length < 4) return;
                dev.ActiveSession = s;
                InputInjector.MouseMove(BinaryPrimitives.ReadInt16BigEndian(p), BinaryPrimitives.ReadInt16BigEndian(p[2..]));
                break;
            case Protocol.MouseButton:
                if (p.Length < 2) return;
                dev.ActiveSession = s;
                dev.MouseButton(p[0], p[1] != 0);
                break;
            case Protocol.Scroll:
                if (p.Length < 4) return;
                dev.ActiveSession = s;
                InputInjector.Scroll(BinaryPrimitives.ReadInt16BigEndian(p), BinaryPrimitives.ReadInt16BigEndian(p[2..]));
                break;
            case Protocol.StateSync:
            {
                if (p.Length < 1) return;
                int n = p[0];
                if (p.Length < 1 + n * 2) return;
                var keys = new List<ushort>(n);
                for (int i = 0; i < n; i++) keys.Add(BinaryPrimitives.ReadUInt16BigEndian(p[(1 + i * 2)..]));
                byte buttons = p.Length > 1 + n * 2 ? p[1 + n * 2] : (byte)0;
                dev.ActiveSession = s;
                dev.Sync(keys, buttons);
                break;
            }
            case Protocol.ReleaseAll:
                dev.ReleaseAll();
                Joystick.Neutral(s.DeviceId);
                break;
            case Protocol.Joystick:
            {
                if (p.Length < 1) return;
                int n = Math.Min((int)p[0], 8);
                if (p.Length < 1 + n * 2 + 4) return;
                Span<short> axes = stackalloc short[n];
                for (int i = 0; i < n; i++) axes[i] = BinaryPrimitives.ReadInt16BigEndian(p[(1 + i * 2)..]);
                uint buttons = BinaryPrimitives.ReadUInt32BigEndian(p[(1 + n * 2)..]);
                byte hold = p.Length > 5 + n * 2 ? p[5 + n * 2] : (byte)0;
                dev.ActiveSession = s;
                Joystick.Update(s.DeviceId!, axes, buttons, hold);
                break;
            }
            case Protocol.Text:
                dev.ActiveSession = s;
                InputInjector.Text(Session.Utf8(p));
                break;
            case Protocol.Command:
                HandleCommand(s, p);
                break;
        }
    }

    private void HandleCommand(Session s, ReadOnlySpan<byte> p)
    {
        CommandMsg? cmd;
        try { cmd = JsonSerializer.Deserialize<CommandMsg>(p, Protocol.Json); }
        catch { return; }
        if (cmd == null) return;
        switch (cmd.Cmd)
        {
            case "setLayout" when cmd.Arg != null:
                Layouts.SwitchTo(cmd.Arg);
                break;
            case "requestState":
                s.SendJson(Protocol.PcState, WithAddresses(Layouts.Current));
                break;
        }
    }

    private void HandleHello(Session s, ReadOnlySpan<byte> p)
    {
        HelloMsg? hello;
        try { hello = JsonSerializer.Deserialize<HelloMsg>(p, Protocol.Json); }
        catch { hello = null; }
        if (hello == null || string.IsNullOrWhiteSpace(hello.DeviceId))
        {
            s.Close();
            return;
        }
        var name = string.IsNullOrWhiteSpace(hello.Name) ? "iPad" : hello.Name.Trim();
        if (name.Length > 64) name = name[..64];
        s.DeviceId = hello.DeviceId;
        s.DeviceName = name;

        var trusted = Config.FindTrusted(hello.DeviceId, hello.Token);
        if (trusted != null)
        {
            trusted.Name = name;
            trusted.LastSeen = DateTime.Now;
            Accept(s, trusted.Token);
            return;
        }

        if (s.IsLoopback && Adb?.Active == true) s.ViaAdb = true;
        if (s.Cable)
        {
            // A physical cable plus the device's own trust prompt ("Trust this computer" on the iPad,
            // "Allow USB debugging" on Android) is proof enough.
            // This also pairs the device for Wi-Fi.
            var d = Config.Trust(hello.DeviceId, name);
            Accept(s, d.Token);
            return;
        }

        PairingRequest req;
        lock (_gate)
        {
            if (_pendingPairing.Count >= 3)
            {
                s.SendJson(Protocol.HelloAck, new HelloAckMsg { Status = "denied", Message = "busy" });
                s.Close();
                return;
            }
            var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
            req = new PairingRequest { Session = s, DeviceId = hello.DeviceId, DeviceName = name, Code = code };
            _pendingPairing[hello.DeviceId + "|" + s.GetHashCode()] = req;
        }
        s.SendJson(Protocol.HelloAck, new HelloAckMsg { Status = "pending", Code = req.Code });
        Log.Info($"Pairing requested by {name} from {s.Remote}");
        PairingRequested?.Invoke(req);
    }

    public void ResolvePairing(PairingRequest req, bool allow)
    {
        lock (_gate)
        {
            var key = _pendingPairing.FirstOrDefault(kv => ReferenceEquals(kv.Value, req)).Key;
            if (key == null) return;
            _pendingPairing.Remove(key);
        }
        if (req.Session.IsClosed) return;
        if (allow)
        {
            var d = Config.Trust(req.DeviceId, req.DeviceName);
            Accept(req.Session, d.Token);
        }
        else
        {
            req.Session.SendJson(Protocol.HelloAck, new HelloAckMsg { Status = "denied", Message = "rejected" });
            req.Session.Close();
        }
    }

    private void Accept(Session s, string token)
    {
        s.Authed = true;
        s.SendJson(Protocol.HelloAck, new HelloAckMsg { Status = "ok", Token = token });
        s.SendJson(Protocol.PcState, WithAddresses(Layouts.Current));
        Log.Info($"Authenticated {s}");
        SessionsChanged?.Invoke();
        DeviceConnected?.Invoke(s);
    }

    private PcStateMsg WithAddresses(PcStateMsg state)
    {
        state.Addresses = WifiServer.LocalAddresses();
        state.Joystick = Joystick.Status;
        state.Port = Config.WifiPort;
        return state;
    }

    public bool AnyDeviceConnected() => Sessions().Any(s => s.Authed);

    public void ForgetDevice(string id)
    {
        Config.Forget(id);
        foreach (var s in Sessions().Where(x => x.DeviceId == id && x.Transport == Transport.Wifi)) s.Close();
    }

    public void ReleaseEverything()
    {
        lock (_gate) foreach (var d in _devices.Values) d.ReleaseAll();
    }

    /// <summary>
    /// Dead-man switch: if the iPad app freezes with keys down (its socket stays open, so the
    /// session doesn't drop), let go of everything instead of leaving a hotkey held.
    /// </summary>
    private void CheckStalls()
    {
        List<DeviceInput> stalled;
        lock (_gate)
            stalled = _devices.Values.Where(d => d.HeldCount > 0 && d.SilentMs > DeviceInput.StallReleaseMs).ToList();
        foreach (var d in stalled)
        {
            Log.Warn($"iPad {d.DeviceId} stopped responding for {d.SilentMs} ms with keys held: releasing all");
            d.ReleaseAll();
        }
        // A frozen iPad must not leave the aircraft banking: centre the stick after a second of silence.
        if (Joystick.Engaged && Joystick.Owner is { } owner)
        {
            DeviceInput? od;
            lock (_gate) _devices.TryGetValue(owner, out od);
            if (od != null && od.SilentMs > 1000)
            {
                Log.Warn($"iPad {owner} silent with the joystick deflected: centring");
                Joystick.Neutral(owner);
            }
        }
    }

    public void Dispose()
    {
        _stallTimer.Dispose();
        ReleaseEverything();
        Joystick.Dispose();
        Updater.Dispose();
        Wifi?.Dispose();
        Usb?.Dispose();
        Adb?.Dispose();
        foreach (var s in Sessions()) s.Close();
        Layouts.Dispose();
    }
}
