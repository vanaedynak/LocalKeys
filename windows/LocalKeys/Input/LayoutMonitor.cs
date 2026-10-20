using System.Globalization;
using System.Text;
using static LocalKeys.Native;

namespace LocalKeys.Input;

/// <summary>
/// Watches the keyboard layout of the foreground window and the lock-key LEDs, and computes
/// the real legends (characters) for every printable scan code of the current layout,
/// so the iPad keycaps always show exactly what will be typed (EN / RU / UA / anything else).
/// </summary>
internal sealed class LayoutMonitor : IDisposable
{
    private static readonly ushort[] PrintableCodes = BuildPrintable();

    private readonly Timer _timer;
    private IntPtr _lastHkl = IntPtr.Zero;
    private int _lastLocks = -1;
    private string _lastListSig = "";
    private PcStateMsg _state = new();
    private readonly object _gate = new();

    public event Action<PcStateMsg>? Changed;

    public LayoutMonitor()
    {
        _state.PcName = Environment.MachineName;
        _timer = new Timer(_ => Poll(), null, 0, 200);
    }

    public PcStateMsg Current
    {
        get { lock (_gate) return _state; }
    }

    private static ushort[] BuildPrintable()
    {
        var list = new List<ushort> { 0x29, 0x2B, 0x56 };
        for (ushort c = 0x02; c <= 0x0D; c++) list.Add(c);
        for (ushort c = 0x10; c <= 0x1B; c++) list.Add(c);
        for (ushort c = 0x1E; c <= 0x28; c++) list.Add(c);
        for (ushort c = 0x2C; c <= 0x35; c++) list.Add(c);
        return list.ToArray();
    }

    private static IntPtr ForegroundHkl()
    {
        var hwnd = GetForegroundWindow();
        uint tid = GetWindowThreadProcessId(hwnd, out _);
        // Use the focused control's thread when possible (e.g. hosted windows).
        var gui = new GUITHREADINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<GUITHREADINFO>() };
        if (tid != 0 && GetGUIThreadInfo(tid, ref gui) && gui.hwndFocus != IntPtr.Zero)
        {
            uint ftid = GetWindowThreadProcessId(gui.hwndFocus, out _);
            if (ftid != 0) tid = ftid;
        }
        var hkl = GetKeyboardLayout(tid);
        return hkl;
    }

    private int _polling;

    private void Poll()
    {
        if (Interlocked.Exchange(ref _polling, 1) == 1) return;
        try
        {
            var hkl = ForegroundHkl();
            if (hkl == IntPtr.Zero) hkl = _lastHkl != IntPtr.Zero ? _lastHkl : GetKeyboardLayout(0);

            int locks = (GetKeyState(0x14) & 1) | ((GetKeyState(0x90) & 1) << 1) | ((GetKeyState(0x91) & 1) << 2);

            int n = GetKeyboardLayoutList(0, null);
            var arr = new IntPtr[Math.Max(n, 0)];
            if (n > 0) GetKeyboardLayoutList(n, arr);
            string sig = string.Join(",", arr.Select(h => h.ToInt64().ToString("X")));

            if (hkl == _lastHkl && locks == _lastLocks && sig == _lastListSig) return;

            bool layoutChanged = hkl != _lastHkl || sig != _lastListSig;
            _lastHkl = hkl;
            _lastLocks = locks;
            _lastListSig = sig;

            PcStateMsg next;
            lock (_gate)
            {
                next = new PcStateMsg
                {
                    PcName = Environment.MachineName,
                    Caps = (locks & 1) != 0,
                    Num = (locks & 2) != 0,
                    Scroll = (locks & 4) != 0,
                    Elevated = Elevation.IsElevated,
                    LayoutId = Id(hkl),
                    Lang = ShortLang(hkl),
                    LayoutName = LongName(hkl),
                    Layouts = arr.Select(h => new KbLayoutInfo { Id = Id(h), Lang = ShortLang(h), Name = LongName(h) }).ToList(),
                    Legends = layoutChanged ? ComputeLegends(hkl) : _state.Legends,
                };
                _state = next;
            }
            Changed?.Invoke(next);
        }
        catch (Exception ex)
        {
            Log.Error("Layout poll", ex);
        }
        finally
        {
            Volatile.Write(ref _polling, 0);
        }
    }

    private static string Id(IntPtr hkl) => hkl.ToInt64().ToString("X");

    private static CultureInfo? Culture(IntPtr hkl)
    {
        try { return CultureInfo.GetCultureInfo((int)(hkl.ToInt64() & 0xFFFF)); }
        catch { return null; }
    }

    private static string ShortLang(IntPtr hkl)
    {
        var c = Culture(hkl);
        if (c == null) return "??";
        var two = c.TwoLetterISOLanguageName.ToUpperInvariant();
        return two == "UK" ? "UA" : two;
    }

    private static string LongName(IntPtr hkl)
    {
        var c = Culture(hkl);
        if (c == null) return Id(hkl);
        var name = c.NativeName;
        return name.Length > 0 ? char.ToUpper(name[0]) + name[1..] : name;
    }

    private static Dictionary<string, string[]> ComputeLegends(IntPtr hkl)
    {
        var result = new Dictionary<string, string[]>();
        var normal = new byte[256];
        var shifted = new byte[256];
        shifted[0x10] = 0x80; // VK_SHIFT
        shifted[0xA0] = 0x80; // VK_LSHIFT
        var sb = new StringBuilder(8);
        foreach (var sc in PrintableCodes)
        {
            uint vk = MapVirtualKeyEx(sc, 1 /* MAPVK_VSC_TO_VK */, hkl);
            if (vk == 0) continue;
            string a = Translate(vk, sc, normal, hkl, sb);
            string b = Translate(vk, sc, shifted, hkl, sb);
            if (a.Length == 0 && b.Length == 0) continue;
            result[sc.ToString()] = new[] { a, b };
        }
        return result;
    }

    private static string Translate(uint vk, uint sc, byte[] state, IntPtr hkl, StringBuilder sb)
    {
        sb.Clear();
        // Flag 0x4: do not change the keyboard state (no dead-key side effects), Windows 10 1607+.
        int r = ToUnicodeEx(vk, sc, state, sb, 8, 0x4, hkl);
        if (r == 0) return "";
        var s = sb.ToString();
        if (r < 0) s = s.Length > 0 ? s[..1] : ""; // dead key: show its base character
        else if (s.Length > r) s = s[..r];
        return s.Any(char.IsControl) ? "" : s;
    }

    /// <summary>Ask the foreground window to switch to the given layout.</summary>
    public void SwitchTo(string id)
    {
        try
        {
            var hkl = new IntPtr(long.Parse(id, NumberStyles.HexNumber));
            var hwnd = GetForegroundWindow();
            PostMessage(hwnd, WM_INPUTLANGCHANGEREQUEST, IntPtr.Zero, hkl);
        }
        catch (Exception ex)
        {
            Log.Error("Switch layout", ex);
        }
    }

    public void ForceRefresh()
    {
        _lastHkl = IntPtr.Zero;
        Poll();
    }

    public void Dispose() => _timer.Dispose();
}
