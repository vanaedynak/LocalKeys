using static LocalKeys.Native;
using Timer = System.Threading.Timer;

namespace LocalKeys.Input;

/// <summary>
/// Input state of one iPad. Tracks what is held so that every press gets exactly one release
/// (no stuck keys on disconnect) and emulates hardware typematic auto-repeat:
/// Windows does not auto-repeat injected keys, a real keyboard does it in firmware.
/// </summary>
internal sealed class DeviceInput : IDisposable
{
    private readonly object _gate = new();
    private readonly HashSet<ushort> _keys = new();
    private byte _buttons;
    private readonly Timer _repeatTimer;
    private ushort _repeatCode;
    private bool _repeating;

    public string DeviceId { get; }
    public object? ActiveSession { get; set; }

    /// <summary>The iPad pings twice a second from its UI thread: silence means the app froze.</summary>
    private long _lastRx = Environment.TickCount64;
    private const int RepeatStallMs = 700;
    public const int StallReleaseMs = 2000;

    public void MarkAlive() => Volatile.Write(ref _lastRx, Environment.TickCount64);
    public long SilentMs => Environment.TickCount64 - Volatile.Read(ref _lastRx);

    public DeviceInput(string deviceId)
    {
        DeviceId = deviceId;
        _repeatTimer = new Timer(OnRepeat, null, Timeout.Infinite, Timeout.Infinite);
    }

    public int HeldCount
    {
        get { lock (_gate) return _keys.Count + (_buttons != 0 ? 1 : 0); }
    }

    public void KeyDown(ushort code)
    {
        lock (_gate)
        {
            if (!_keys.Add(code)) return;
            InputInjector.Key(code, true);
            if (!InputInjector.IsModifier(code) && code != 0x3A && code != 0x45 && code != 0x46)
                StartRepeat(code);
        }
    }

    public void KeyUp(ushort code)
    {
        lock (_gate)
        {
            if (!_keys.Remove(code)) return;
            if (_repeating && _repeatCode == code) StopRepeat();
            InputInjector.Key(code, false);
        }
    }

    public void MouseButton(int button, bool down)
    {
        lock (_gate)
        {
            byte bit = (byte)(1 << button);
            bool held = (_buttons & bit) != 0;
            if (down == held) return;
            _buttons = down ? (byte)(_buttons | bit) : (byte)(_buttons & ~bit);
            InputInjector.MouseButton(button, down);
        }
    }

    /// <summary>Bring the PC in line with the iPad's view of what is held (used after a transport switch).</summary>
    public void Sync(IReadOnlyCollection<ushort> keys, byte buttons)
    {
        lock (_gate)
        {
            foreach (var k in _keys.Where(k => !keys.Contains(k)).ToList()) KeyUp(k);
            foreach (var k in keys) if (!_keys.Contains(k)) { _keys.Add(k); InputInjector.Key(k, true); }
            for (int b = 0; b < 5; b++) MouseButton(b, (buttons & (1 << b)) != 0);
        }
    }

    public void ReleaseAll()
    {
        lock (_gate)
        {
            StopRepeat();
            // Release non-modifiers first, then modifiers, like fingers leaving a real keyboard.
            foreach (var k in _keys.OrderBy(k => InputInjector.IsModifier(k) ? 1 : 0).ToList())
                InputInjector.Key(k, false);
            _keys.Clear();
            for (int b = 0; b < 5; b++)
                if ((_buttons & (1 << b)) != 0) InputInjector.MouseButton(b, false);
            _buttons = 0;
        }
    }

    private void StartRepeat(ushort code)
    {
        _repeatCode = code;
        _repeating = true;
        _repeatTimer.Change(RepeatDelayMs(), RepeatIntervalMs());
    }

    private void StopRepeat()
    {
        _repeating = false;
        _repeatTimer.Change(Timeout.Infinite, Timeout.Infinite);
    }

    private void OnRepeat(object? _)
    {
        lock (_gate)
        {
            if (!_repeating || !_keys.Contains(_repeatCode)) { StopRepeat(); return; }
            // Don't type "aaaaaa" while the iPad is not responding; the key itself stays held.
            if (SilentMs > RepeatStallMs) return;
            InputInjector.Key(_repeatCode, true);
        }
    }

    private static int RepeatDelayMs()
    {
        int v = 1;
        SystemParametersInfo(SPI_GETKEYBOARDDELAY, 0, ref v, 0);
        return 250 * (Math.Clamp(v, 0, 3) + 1);
    }

    private static int RepeatIntervalMs()
    {
        int v = 31;
        SystemParametersInfo(SPI_GETKEYBOARDSPEED, 0, ref v, 0);
        double cps = 2.5 + Math.Clamp(v, 0, 31) * (27.5 / 31.0);
        return (int)Math.Round(1000.0 / cps);
    }

    public void Dispose()
    {
        ReleaseAll();
        _repeatTimer.Dispose();
    }
}
