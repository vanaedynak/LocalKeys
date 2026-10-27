using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace LocalKeys.Net;

internal enum Transport { Wifi, Usb }

/// <summary>
/// One framed connection to an iPad (over LAN or through the usbmux USB tunnel).
/// A dedicated thread does blocking reads: the lowest-latency path from socket to SendInput.
/// </summary>
internal sealed class Session
{
    private readonly Socket _socket;
    private readonly NetworkStream _stream;
    private readonly AgentCore _core;
    private readonly object _writeGate = new();
    private volatile bool _closed;

    public Transport Transport { get; }
    public string Remote { get; }
    public string? DeviceId { get; set; }
    public string? DeviceName { get; set; }
    public bool Authed { get; set; }
    public DateTime Connected { get; } = DateTime.Now;
    public event Action<Session>? Closed;

    public Session(Socket socket, Transport transport, AgentCore core, string remote)
    {
        _socket = socket;
        _socket.NoDelay = true;
        _socket.ReceiveTimeout = 8000;
        _socket.SendTimeout = 3000;
        _stream = new NetworkStream(socket, true);
        Transport = transport;
        _core = core;
        Remote = remote;
    }

    public void Start()
    {
        var t = new Thread(ReadLoop) { IsBackground = true, Name = $"Session {Transport} {Remote}", Priority = ThreadPriority.AboveNormal };
        t.Start();
        SendJson(Protocol.ServerHello, new ServerHelloMsg { PcId = _core.Config.PcId, PcName = Environment.MachineName });
    }

    private void ReadExact(byte[] buf, int len)
    {
        int off = 0;
        while (off < len)
        {
            int n = _stream.Read(buf, off, len - off);
            if (n <= 0) throw new EndOfStreamException();
            off += n;
        }
    }

    private void ReadLoop()
    {
        var header = new byte[2];
        var body = new byte[65536];
        try
        {
            while (!_closed)
            {
                ReadExact(header, 2);
                int len = BinaryPrimitives.ReadUInt16BigEndian(header);
                if (len == 0) throw new InvalidDataException("empty frame");
                ReadExact(body, len);
                _core.HandleFrame(this, body[0], new ReadOnlySpan<byte>(body, 1, len - 1));
            }
        }
        catch (Exception ex) when (ex is IOException or SocketException or EndOfStreamException or ObjectDisposedException or InvalidDataException)
        {
            // normal disconnect
        }
        catch (Exception ex)
        {
            Log.Error($"Session {Remote} crashed", ex);
        }
        Close();
    }

    public void Send(byte type, ReadOnlySpan<byte> payload)
    {
        if (_closed) return;
        var frame = new byte[payload.Length + 3];
        BinaryPrimitives.WriteUInt16BigEndian(frame, (ushort)(payload.Length + 1));
        frame[2] = type;
        payload.CopyTo(frame.AsSpan(3));
        try
        {
            lock (_writeGate) _stream.Write(frame, 0, frame.Length);
        }
        catch
        {
            Close();
        }
    }

    public void SendJson<T>(byte type, T msg) =>
        Send(type, JsonSerializer.SerializeToUtf8Bytes(msg, Protocol.Json));

    public void Close()
    {
        if (_closed) return;
        _closed = true;
        try { _socket.Shutdown(SocketShutdown.Both); } catch { }
        try { _stream.Dispose(); } catch { }
        Closed?.Invoke(this);
    }

    public bool IsClosed => _closed;

    public bool IsLoopback => Transport == Transport.Wifi && (Remote == "127.0.0.1" || Remote == "::1");

    /// <summary>An Android phone on the cable: a loopback session through the ADB reverse tunnel.</summary>
    public bool ViaAdb { get; set; }

    /// <summary>Over a USB cable (iPad usbmux or Android ADB).</summary>
    public bool Cable => Transport == Transport.Usb || ViaAdb;

    public override string ToString() => $"{(ViaAdb ? "Adb" : Transport.ToString())}:{DeviceName ?? Remote}";

    public static string Utf8(ReadOnlySpan<byte> data) => Encoding.UTF8.GetString(data);
}
