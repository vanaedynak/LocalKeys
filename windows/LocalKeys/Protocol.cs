using System.Text.Json;
using System.Text.Json.Serialization;

namespace LocalKeys;

/// <summary>
/// Wire format (both directions): [u16 big-endian length of (type + payload)] [u8 type] [payload].
/// Hot-path messages (keys, mouse) are compact binary; rare control messages carry UTF-8 JSON.
/// Must stay in sync with ios/LocalKeys/Net/Protocol.swift.
/// </summary>
internal static class Protocol
{
    public const int Version = 1;
    public const int WifiPort = 47810;   // PC listens here (Wi-Fi / LAN)
    public const int UsbPort = 47811;    // iPad listens here on loopback, reached through usbmux
    public const string BonjourType = "_localkeys._tcp";

    public const byte ServerHello = 0x00; // PC -> iPad  JSON ServerHelloMsg
    public const byte Hello = 0x01;       // iPad -> PC  JSON HelloMsg
    public const byte HelloAck = 0x02;    // PC -> iPad  JSON HelloAckMsg
    public const byte Ping = 0x03;        // either, 8 bytes opaque, answered with Pong
    public const byte Pong = 0x04;
    public const byte KeyDown = 0x10;     // u16 code
    public const byte KeyUp = 0x11;       // u16 code
    public const byte StateSync = 0x12;   // u8 n, n * u16 code, u8 mouse-button mask
    public const byte ReleaseAll = 0x13;
    public const byte Text = 0x14;        // UTF-8 text
    public const byte MouseMove = 0x20;   // i16 dx, i16 dy
    public const byte MouseButton = 0x21; // u8 button, u8 down
    public const byte Scroll = 0x22;      // i16 vertical, i16 horizontal (1/120 notch units)
    public const byte Joystick = 0x23;    // u8 n, n * i16 axis, u32 buttons, u8 mask of axes that hold position
    public const byte Command = 0x30;     // iPad -> PC JSON CommandMsg
    public const byte PcState = 0x40;     // PC -> iPad JSON PcStateMsg
    public const byte ShowUi = 0x50;      // local launcher -> agent (loopback only): open the window

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };
}

internal sealed class ServerHelloMsg
{
    public int V { get; set; } = Protocol.Version;
    public string PcId { get; set; } = "";
    public string PcName { get; set; } = "";
}

internal sealed class HelloMsg
{
    public int V { get; set; }
    public string DeviceId { get; set; } = "";
    public string Name { get; set; } = "";
    public string? Token { get; set; }
}

internal sealed class HelloAckMsg
{
    public string Status { get; set; } = "ok"; // ok | pending | denied
    public string? Token { get; set; }
    public string? Code { get; set; }
    public string? Message { get; set; }
}

internal sealed class CommandMsg
{
    public string Cmd { get; set; } = "";
    public string? Arg { get; set; }
}

internal sealed class KbLayoutInfo
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Lang { get; set; } = "";
}

internal sealed class PcStateMsg
{
    public string PcName { get; set; } = "";
    public string? LayoutId { get; set; }
    public string? Lang { get; set; }
    public string? LayoutName { get; set; }
    public List<KbLayoutInfo> Layouts { get; set; } = new();
    /// <summary>scan code (decimal string) -> [normal, shifted]</summary>
    public Dictionary<string, string[]> Legends { get; set; } = new();
    public bool Caps { get; set; }
    public bool Num { get; set; }
    public bool Scroll { get; set; }
    public bool Elevated { get; set; }
    /// <summary>LAN IPv4 addresses of this PC: the iPad keeps them as a fallback when auto-discovery fails.</summary>
    public List<string> Addresses { get; set; } = new();
    public int Port { get; set; } = Protocol.WifiPort;
    /// <summary>Virtual joystick (vJoy): ok | missing | busy | error.</summary>
    public string? Joystick { get; set; }
}
