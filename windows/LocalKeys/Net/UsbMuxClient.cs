using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Security;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace LocalKeys.Net;

/// <summary>
/// Wired connection over the USB-C cable. iPadOS exposes app TCP ports to the computer through
/// "usbmux" — the same channel Xcode/iTunes use. On Windows it is provided by Apple Mobile Device
/// Service (installed with "Apple Devices" from Microsoft Store or iTunes) on 127.0.0.1:27015.
/// We poll the attached devices and open a tunnel to the LocalKeys app's port on the iPad.
/// No Wi-Fi or network is involved, and the iPad charges at the same time.
/// </summary>
internal sealed class UsbMuxClient : IDisposable
{
    private const int MuxPort = 27015;
    private readonly AgentCore _core;
    private readonly Dictionary<long, Session> _sessions = new();
    private readonly Dictionary<long, DateTime> _retryAfter = new();
    private readonly object _gate = new();
    private Thread? _thread;
    private volatile bool _stopped;
    private int _tag;

    public bool ServiceAvailable { get; private set; }
    public int UsbDevices { get; private set; }

    public UsbMuxClient(AgentCore core) => _core = core;

    public void Start()
    {
        _thread = new Thread(Loop) { IsBackground = true, Name = "UsbMux" };
        _thread.Start();
    }

    private void Loop()
    {
        bool loggedMissing = false;
        while (!_stopped)
        {
            try
            {
                var devices = ListDevices();
                ServiceAvailable = true;
                loggedMissing = false;
                UsbDevices = devices.Count;
                foreach (var id in devices)
                {
                    lock (_gate)
                    {
                        if (_sessions.ContainsKey(id)) continue;
                        if (_retryAfter.TryGetValue(id, out var t) && DateTime.UtcNow < t) continue;
                    }
                    TryConnect(id);
                }
            }
            catch (Exception ex)
            {
                ServiceAvailable = false;
                UsbDevices = 0;
                if (!loggedMissing)
                {
                    Log.Info($"usbmuxd not reachable ({ex.Message}). USB mode needs Apple Mobile Device Service.");
                    loggedMissing = true;
                }
            }
            Thread.Sleep(ServiceAvailable ? 1000 : 5000);
        }
    }

    private void TryConnect(long deviceId)
    {
        Socket? s = null;
        try
        {
            s = OpenMux();
            ushort port = (ushort)Protocol.UsbPort;
            int portBE = ((port & 0xFF) << 8) | (port >> 8);
            SendPlist(s, new Dictionary<string, object>
            {
                ["MessageType"] = "Connect",
                ["ClientVersionString"] = "LocalKeys",
                ["ProgName"] = "LocalKeys",
                ["DeviceID"] = deviceId,
                ["PortNumber"] = portBE,
                ["kLibUSBMuxVersion"] = 3,
            });
            var reply = ReadPlist(s);
            long result = reply.TryGetValue("Number", out var n) ? Convert.ToInt64(n) : -1;
            if (result != 0)
            {
                // 3 = connection refused: the LocalKeys app is not open on this iPad right now.
                s.Dispose();
                lock (_gate) _retryAfter[deviceId] = DateTime.UtcNow.AddMilliseconds(1200);
                return;
            }

            var session = new Session(s, Transport.Usb, _core, $"usb#{deviceId}");
            lock (_gate) _sessions[deviceId] = session;
            session.Closed += _ =>
            {
                lock (_gate)
                {
                    _sessions.Remove(deviceId);
                    _retryAfter[deviceId] = DateTime.UtcNow.AddMilliseconds(800);
                }
            };
            Log.Info($"USB tunnel opened to device {deviceId}");
            _core.AddSession(session);
            session.Start();
        }
        catch (Exception ex)
        {
            s?.Dispose();
            lock (_gate) _retryAfter[deviceId] = DateTime.UtcNow.AddSeconds(2);
            Log.Warn($"USB connect to {deviceId} failed: {ex.Message}");
        }
    }

    private List<long> ListDevices()
    {
        using var s = OpenMux();
        SendPlist(s, new Dictionary<string, object>
        {
            ["MessageType"] = "ListDevices",
            ["ClientVersionString"] = "LocalKeys",
            ["ProgName"] = "LocalKeys",
            ["kLibUSBMuxVersion"] = 3,
        });
        var reply = ReadPlist(s);
        var result = new List<long>();
        if (reply.TryGetValue("DeviceList", out var listObj) && listObj is List<object> list)
        {
            foreach (var item in list.OfType<Dictionary<string, object>>())
            {
                if (!item.TryGetValue("Properties", out var pObj) || pObj is not Dictionary<string, object> props) continue;
                var type = props.TryGetValue("ConnectionType", out var ct) ? ct as string : null;
                if (type != "USB") continue;
                if (props.TryGetValue("DeviceID", out var id)) result.Add(Convert.ToInt64(id));
            }
        }
        return result;
    }

    private static Socket OpenMux()
    {
        var s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp)
        {
            NoDelay = true,
            ReceiveTimeout = 3000,
            SendTimeout = 3000,
        };
        try
        {
            s.Connect(new IPEndPoint(IPAddress.Loopback, MuxPort));
        }
        catch
        {
            s.Dispose();
            throw;
        }
        return s;
    }

    private void SendPlist(Socket s, Dictionary<string, object> dict)
    {
        var xml = Encoding.UTF8.GetBytes(ToPlist(dict));
        var buf = new byte[16 + xml.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(0), (uint)buf.Length);
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(4), 1);  // version: plist
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(8), 8);  // message: plist
        BinaryPrimitives.WriteUInt32LittleEndian(buf.AsSpan(12), (uint)Interlocked.Increment(ref _tag));
        xml.CopyTo(buf, 16);
        int off = 0;
        while (off < buf.Length) off += s.Send(buf, off, buf.Length - off, SocketFlags.None);
    }

    private static void ReadExact(Socket s, byte[] buf, int len)
    {
        int off = 0;
        while (off < len)
        {
            int n = s.Receive(buf, off, len - off, SocketFlags.None);
            if (n <= 0) throw new EndOfStreamException();
            off += n;
        }
    }

    private static Dictionary<string, object> ReadPlist(Socket s)
    {
        var header = new byte[16];
        ReadExact(s, header, 16);
        int len = (int)BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (len < 16 || len > 1 << 20) throw new InvalidDataException("bad usbmux header");
        var body = new byte[len - 16];
        ReadExact(s, body, body.Length);
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null };
        using var reader = XmlReader.Create(new MemoryStream(body), settings);
        var doc = XDocument.Load(reader);
        var root = doc.Root?.Elements().FirstOrDefault();
        return root != null && ParseNode(root) is Dictionary<string, object> d ? d : new();
    }

    private static object ParseNode(XElement e)
    {
        switch (e.Name.LocalName)
        {
            case "dict":
                var dict = new Dictionary<string, object>();
                var children = e.Elements().ToList();
                for (int i = 0; i + 1 < children.Count; i += 2)
                    dict[children[i].Value] = ParseNode(children[i + 1]);
                return dict;
            case "array":
                return e.Elements().Select(ParseNode).ToList();
            case "integer":
                return long.TryParse(e.Value, out var l) ? l : 0L;
            case "true": return true;
            case "false": return false;
            case "data":
                try { return Convert.FromBase64String(e.Value.Trim()); } catch { return Array.Empty<byte>(); }
            default:
                return e.Value;
        }
    }

    private static string ToPlist(Dictionary<string, object> dict)
    {
        var sb = new StringBuilder();
        sb.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n");
        sb.Append("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n");
        sb.Append("<plist version=\"1.0\">\n<dict>\n");
        foreach (var (k, v) in dict)
        {
            sb.Append("\t<key>").Append(SecurityElement.Escape(k)).Append("</key>\n");
            switch (v)
            {
                case int or long:
                    sb.Append("\t<integer>").Append(Convert.ToInt64(v)).Append("</integer>\n");
                    break;
                case bool b:
                    sb.Append(b ? "\t<true/>\n" : "\t<false/>\n");
                    break;
                default:
                    sb.Append("\t<string>").Append(SecurityElement.Escape(v.ToString() ?? "")).Append("</string>\n");
                    break;
            }
        }
        sb.Append("</dict>\n</plist>\n");
        return sb.ToString();
    }

    public void Dispose()
    {
        _stopped = true;
        lock (_gate)
        {
            foreach (var s in _sessions.Values.ToList()) s.Close();
        }
    }
}
