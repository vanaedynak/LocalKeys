using static LocalKeys.Native;

namespace LocalKeys.Input;

/// <summary>
/// Low-level injection through SendInput. Keys are sent as hardware scan codes (set 1),
/// exactly like a physical keyboard, so games using DirectInput / Raw Input see them too
/// and the active Windows keyboard layout (EN/RU/UA...) decides which characters appear.
/// Code format: low byte = scan code, high byte 0xE0 = extended (E0-prefixed) key.
/// </summary>
internal static class InputInjector
{
    public const ushort Pause = 0xE145;   // pseudo code: E1 1D 45 on real hardware
    public const ushort NumLock = 0x0045;
    public const ushort PrintScreen = 0xE037;

    // Keys that are more reliable when injected through their virtual-key code.
    private static readonly Dictionary<ushort, (ushort vk, bool ext)> VkKeys = new()
    {
        [0xE020] = (0xAD, true), // Volume mute
        [0xE02E] = (0xAE, true), // Volume down
        [0xE030] = (0xAF, true), // Volume up
        [0xE019] = (0xB0, true), // Next track
        [0xE010] = (0xB1, true), // Previous track
        [0xE024] = (0xB2, true), // Stop
        [0xE022] = (0xB3, true), // Play/Pause
        [0xE021] = (0xB7, true), // Calculator (Launch App 2)
        [0xE032] = (0xAC, true), // Browser home
        [0xE06C] = (0xB4, true), // Mail
        [0xE06B] = (0xB6, true), // My computer (Launch App 1)
        [0xE06A] = (0xA6, true), // Browser back
        [0xE069] = (0xA7, true), // Browser forward
        [Pause] = (0x13, false),
        [NumLock] = (0x90, true),
        [PrintScreen] = (0x2C, true),
    };

    private static readonly HashSet<ushort> ModifierCodes = new()
    {
        0x2A, 0x36, 0x1D, 0xE01D, 0x38, 0xE038, 0xE05B, 0xE05C,
    };

    public static bool IsModifier(ushort code) => ModifierCodes.Contains(code);

    public static void Key(ushort code, bool down)
    {
        var input = new INPUT { type = INPUT_KEYBOARD };
        if (VkKeys.TryGetValue(code, out var vk))
        {
            input.U.ki.wVk = vk.vk;
            input.U.ki.wScan = (ushort)(code & 0xFF);
            input.U.ki.dwFlags = (vk.ext ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP);
        }
        else
        {
            bool ext = (code & 0xFF00) == 0xE000;
            input.U.ki.wScan = (ushort)(code & 0xFF);
            input.U.ki.dwFlags = KEYEVENTF_SCANCODE | (ext ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP);
        }
        input.U.ki.dwExtraInfo = ExtraInfo;
        Send(input);
    }

    public static void Text(string text)
    {
        var list = new List<INPUT>(text.Length * 2);
        foreach (var ch in text.Replace("\r\n", "\n"))
        {
            if (ch == '\n')
            {
                Flush(list);
                Key(0x1C, true);
                Key(0x1C, false);
                continue;
            }
            if (ch == '\t')
            {
                Flush(list);
                Key(0x0F, true);
                Key(0x0F, false);
                continue;
            }
            foreach (var up in new[] { false, true })
            {
                var i = new INPUT { type = INPUT_KEYBOARD };
                i.U.ki.wScan = ch;
                i.U.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
                i.U.ki.dwExtraInfo = ExtraInfo;
                list.Add(i);
            }
        }
        Flush(list);
    }

    private static void Flush(List<INPUT> list)
    {
        if (list.Count == 0) return;
        SendInput((uint)list.Count, list.ToArray(), InputSize);
        list.Clear();
    }

    public static void MouseMove(int dx, int dy)
    {
        var i = new INPUT { type = INPUT_MOUSE };
        i.U.mi.dx = dx;
        i.U.mi.dy = dy;
        i.U.mi.dwFlags = MOUSEEVENTF_MOVE;
        i.U.mi.dwExtraInfo = ExtraInfo;
        Send(i);
    }

    public static void MouseButton(int button, bool down)
    {
        var i = new INPUT { type = INPUT_MOUSE };
        i.U.mi.dwExtraInfo = ExtraInfo;
        switch (button)
        {
            case 0: i.U.mi.dwFlags = down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP; break;
            case 1: i.U.mi.dwFlags = down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP; break;
            case 2: i.U.mi.dwFlags = down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP; break;
            case 3: i.U.mi.dwFlags = down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP; i.U.mi.mouseData = 1; break;
            case 4: i.U.mi.dwFlags = down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP; i.U.mi.mouseData = 2; break;
            default: return;
        }
        Send(i);
    }

    public static void Scroll(int vertical, int horizontal)
    {
        if (vertical != 0)
        {
            var i = new INPUT { type = INPUT_MOUSE };
            i.U.mi.dwFlags = MOUSEEVENTF_WHEEL;
            i.U.mi.mouseData = unchecked((uint)vertical);
            i.U.mi.dwExtraInfo = ExtraInfo;
            Send(i);
        }
        if (horizontal != 0)
        {
            var i = new INPUT { type = INPUT_MOUSE };
            i.U.mi.dwFlags = MOUSEEVENTF_HWHEEL;
            i.U.mi.mouseData = unchecked((uint)horizontal);
            i.U.mi.dwExtraInfo = ExtraInfo;
            Send(i);
        }
    }

    private static readonly INPUT[] One = new INPUT[1];
    private static readonly object SendGate = new();

    private static void Send(INPUT input)
    {
        lock (SendGate)
        {
            One[0] = input;
            if (SendInput(1, One, InputSize) == 0)
            {
                // Typically UIPI: the foreground window is elevated and we are not.
                LastFailure = DateTime.UtcNow;
            }
        }
    }

    public static DateTime LastFailure { get; private set; } = DateTime.MinValue;
}
