using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace LocalKeys.Input;

/// <summary>
/// A real game controller for Windows, fed by the iPad's flight stick, throttle and buttons:
/// device 1 of the vJoy driver (free, installed separately). Games such as DCS World see it as an
/// ordinary DirectInput joystick, so axes are bound, curved and tuned in the game itself.
/// vJoyInterface.dll is loaded from the driver's install folder at run time; without the driver
/// the rest of LocalKeys works as before and the iPad shows a hint.
/// </summary>
internal sealed class VirtualJoystick : IDisposable
{
    private const uint Id = 1;
    private const int AxisCount = 8;
    private static readonly uint[] Usages = { 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37 }; // X Y Z Rx Ry Rz Sl0 Sl1

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate bool FnEnabled();
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int FnStatus(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate bool FnId(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate void FnRelinquish(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate bool FnSetAxis(int value, uint id, uint axis);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate bool FnSetBtn(bool value, uint id, byte button);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate int FnButtons(uint id);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate bool FnAxisExist(uint id, uint axis);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)] private delegate bool FnAxisRange(uint id, uint axis, out int value);

    private FnEnabled? _enabled;
    private FnStatus? _status;
    private FnId? _acquire;
    private FnRelinquish? _relinquish;
    private FnId? _reset;
    private FnSetAxis? _setAxis;
    private FnSetBtn? _setBtn;
    private FnButtons? _buttons;
    private FnAxisExist? _axisExist;
    private FnAxisRange? _axisMin;
    private FnAxisRange? _axisMax;

    private readonly object _gate = new();
    private string? _dir;
    private bool _loaded;
    private bool _acquired;
    private DateTime _retryAt = DateTime.MinValue;
    private readonly int[] _min = new int[AxisCount];
    private readonly int[] _max = new int[AxisCount];
    private readonly bool[] _exists = new bool[AxisCount];
    private readonly int[] _axes = new int[AxisCount];
    private readonly int?[] _sent = new int?[AxisCount];
    private uint _sentButtons;
    private int _buttonCount;
    private byte _holdMask;
    private bool _configTried;

    /// <summary>Device (iPad) that moved the joystick last: its silence or disconnect centres the stick.</summary>
    public string? Owner { get; private set; }
    /// <summary>Stick deflected or a button held: something to undo if the iPad goes silent.</summary>
    public bool Engaged { get; private set; }

    /// <summary>ok | missing | busy | error — reported to the iPad and shown in the window.</summary>
    public string Status { get; private set; } = "missing";
    public int ButtonCount => _buttonCount;

    public VirtualJoystick()
    {
        lock (_gate) TryOpen();
    }

    /// <summary>One frame from the iPad: axes -32767..32767, buttons as a bit mask.</summary>
    public void Update(string owner, ReadOnlySpan<short> axes, uint buttons, byte holdMask)
    {
        lock (_gate)
        {
            Owner = owner;
            _holdMask = holdMask;
            for (int i = 0; i < AxisCount; i++) _axes[i] = i < axes.Length ? axes[i] : 0;
            Engaged = buttons != 0 || Enumerable.Range(0, AxisCount).Any(i => (holdMask & (1 << i)) == 0 && _axes[i] != 0);
            Apply(buttons);
        }
    }

    /// <summary>
    /// The iPad went silent, disconnected or asked to release everything: centre the stick and
    /// rudder and let go of the buttons. Throttle-like axes keep their position (no sudden thrust change).
    /// </summary>
    public void Neutral(string? owner = null)
    {
        lock (_gate)
        {
            if (owner != null && owner != Owner) return;
            if (!Engaged) return;
            for (int i = 0; i < AxisCount; i++)
                if ((_holdMask & (1 << i)) == 0) _axes[i] = 0;
            Engaged = false;
            Apply(0);
        }
    }

    private void Apply(uint buttons)
    {
        if (!EnsureAcquired()) return;
        for (int i = 0; i < AxisCount; i++)
        {
            if (!_exists[i] || _sent[i] == _axes[i]) continue;
            // -32767..32767 -> the device's range (vJoy: 0..32767 by default).
            long v = _min[i] + (long)(_axes[i] + 32767) * (_max[i] - _min[i]) / 65534;
            if (_setAxis!((int)v, Id, Usages[i])) _sent[i] = _axes[i];
            else { Lost(); return; }
        }
        uint changed = buttons ^ _sentButtons;
        for (int b = 0; b < 32 && changed != 0; b++)
        {
            uint bit = 1u << b;
            if ((changed & bit) == 0) continue;
            changed &= ~bit;
            if (b >= _buttonCount) continue;
            if (!_setBtn!((buttons & bit) != 0, Id, (byte)(b + 1))) { Lost(); return; }
        }
        _sentButtons = buttons;
    }

    private void Lost()
    {
        Log.Warn("vJoy device stopped accepting input; will re-acquire");
        _acquired = false;
        Status = "error";
        Array.Clear(_sent);
        _sentButtons = 0;
        _retryAt = DateTime.UtcNow.AddSeconds(3);
    }

    private bool EnsureAcquired()
    {
        if (_acquired) return true;
        if (DateTime.UtcNow < _retryAt) return false;
        _retryAt = DateTime.UtcNow.AddSeconds(5);
        TryOpen();
        return _acquired;
    }

    private void TryOpen()
    {
        try
        {
            if (!_loaded && !Load()) { Status = "missing"; return; }
            if (!_enabled!()) { Status = "missing"; return; }
            int st = _status!(Id); // 0 own, 1 free, 2 busy, 3 missing, 4 unknown
            if (st == 2) { Status = "busy"; return; }
            if (st == 3 || st == 4) { Status = "missing"; return; }
            if (st == 1 && !_acquire!(Id)) { Status = "busy"; return; }
            _acquired = true;
            _buttonCount = Math.Clamp(_buttons!(Id), 0, 128);
            for (int i = 0; i < AxisCount; i++)
            {
                _exists[i] = _axisExist!(Id, Usages[i]);
                _min[i] = _axisMin!(Id, Usages[i], out var mn) ? mn : 0;
                _max[i] = _axisMax!(Id, Usages[i], out var mx) && mx > _min[i] ? mx : 32767;
                _sent[i] = null;
            }
            _reset!(Id);
            _sentButtons = 0;
            Status = "ok";
            Log.Info($"vJoy device {Id} acquired: {_exists.Count(e => e)} axes, {_buttonCount} buttons");
            if (_buttonCount < 32) ConfigureButtonsOnce();
        }
        catch (Exception ex)
        {
            Status = "error";
            Log.Error("vJoy", ex);
        }
    }

    /// <summary>
    /// A fresh vJoy install has only 8 buttons on device 1. Reconfigure it once to all 8 axes and
    /// 32 buttons with the driver's own tool (we run with admin rights), then re-acquire.
    /// </summary>
    private void ConfigureButtonsOnce()
    {
        if (_configTried || _dir == null) return;
        _configTried = true;
        var tool = Path.Combine(_dir, "vJoyConfig.exe");
        if (!File.Exists(tool)) return;
        ThreadPool.QueueUserWorkItem(_ =>
        {
            lock (_gate)
            {
                try
                {
                    _relinquish!(Id);
                    _acquired = false;
                    var psi = new ProcessStartInfo(tool, $"{Id} -f -a x y z rx ry rz sl0 sl1 -b 32")
                    {
                        CreateNoWindow = true,
                        UseShellExecute = false,
                    };
                    using var p = Process.Start(psi);
                    if (p != null && !p.WaitForExit(20000)) try { p.Kill(true); } catch { }
                    Log.Info($"vJoy device {Id} reconfigured to 8 axes / 32 buttons (exit {p?.ExitCode})");
                }
                catch (Exception ex)
                {
                    Log.Error("vJoyConfig", ex);
                }
                Thread.Sleep(1500);
                _retryAt = DateTime.MinValue;
                TryOpen();
            }
        });
    }

    private bool Load()
    {
        foreach (var dir in Candidates())
        {
            var dll = Path.Combine(dir, "vJoyInterface.dll");
            if (!File.Exists(dll) || !NativeLibrary.TryLoad(dll, out var h)) continue;
            try
            {
                T F<T>(string name) where T : Delegate => Marshal.GetDelegateForFunctionPointer<T>(NativeLibrary.GetExport(h, name));
                _enabled = F<FnEnabled>("vJoyEnabled");
                _status = F<FnStatus>("GetVJDStatus");
                _acquire = F<FnId>("AcquireVJD");
                _relinquish = F<FnRelinquish>("RelinquishVJD");
                _reset = F<FnId>("ResetVJD");
                _setAxis = F<FnSetAxis>("SetAxis");
                _setBtn = F<FnSetBtn>("SetBtn");
                _buttons = F<FnButtons>("GetVJDButtonNumber");
                _axisExist = F<FnAxisExist>("GetVJDAxisExist");
                _axisMin = F<FnAxisRange>("GetVJDAxisMin");
                _axisMax = F<FnAxisRange>("GetVJDAxisMax");
                _dir = dir;
                _loaded = true;
                Log.Info($"vJoy interface loaded from {dir}");
                return true;
            }
            catch (Exception ex)
            {
                Log.Error($"vJoy interface in {dir}", ex);
            }
        }
        return false;
    }

    private static IEnumerable<string> Candidates()
    {
        var list = new List<string>();
        try
        {
            using var uninstall = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall");
            if (uninstall != null)
                foreach (var name in uninstall.GetSubKeyNames())
                {
                    using var k = uninstall.OpenSubKey(name);
                    if (k?.GetValue("DisplayName") is string dn && dn.StartsWith("vJoy", StringComparison.OrdinalIgnoreCase)
                        && k.GetValue("InstallLocation") is string loc && loc.Length > 0)
                        list.Add(Path.Combine(loc, "x64"));
                }
        }
        catch { }
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        list.Add(Path.Combine(pf, "vJoy", "x64"));
        return list.Distinct(StringComparer.OrdinalIgnoreCase);
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (!_acquired) return;
            try { _reset!(Id); _relinquish!(Id); } catch { }
            _acquired = false;
        }
    }
}
