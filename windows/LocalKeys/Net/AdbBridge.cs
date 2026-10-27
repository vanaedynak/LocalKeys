using System.Diagnostics;

namespace LocalKeys.Net;

/// <summary>
/// Wired connection for Android phones. Android has no usbmux; instead ADB (USB debugging) can
/// expose a PC port on the phone: "adb reverse tcp:47810 tcp:47810" makes 127.0.0.1:47810 on the
/// phone reach the Wi-Fi server here, over the cable. We watch for authorized phones and keep that
/// tunnel up; the phone app connects to its own loopback and arrives here as a loopback session.
/// </summary>
internal sealed class AdbBridge : IDisposable
{
    private readonly int _port;
    private readonly HashSet<string> _tunnels = new();
    private readonly Dictionary<string, DateTime> _verified = new();
    private Thread? _thread;
    private volatile bool _stopped;

    public string? AdbPath { get; private set; }
    /// <summary>Phones with USB debugging allowed and the tunnel up.</summary>
    public int Devices { get; private set; }
    /// <summary>Phones plugged in that still wait for "Allow USB debugging" on their screen.</summary>
    public int Unauthorized { get; private set; }
    public bool Active => Devices > 0;

    public AdbBridge(int port) => _port = port;

    public void Start()
    {
        _thread = new Thread(Loop) { IsBackground = true, Name = "AdbBridge", Priority = ThreadPriority.BelowNormal };
        _thread.Start();
    }

    private void Loop()
    {
        bool loggedMissing = false;
        while (!_stopped)
        {
            try
            {
                AdbPath ??= FindAdb();
                if (AdbPath == null)
                {
                    if (!loggedMissing) Log.Info("adb not found: Android over USB is unavailable (Wi-Fi still works).");
                    loggedMissing = true;
                    Sleep(15000);
                    continue;
                }
                Poll();
            }
            catch (Exception ex)
            {
                Log.Error("ADB bridge", ex);
            }
            Sleep(Devices > 0 || Unauthorized > 0 ? 1500 : 3000);
        }
    }

    private void Sleep(int ms)
    {
        for (int i = 0; i < ms / 250 && !_stopped; i++) Thread.Sleep(250);
    }

    private void Poll()
    {
        var output = Run("devices");
        if (output == null) return;
        var ready = new List<string>();
        int unauthorized = 0;
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("List of") || line.StartsWith("*")) continue;
            var parts = line.Split('\t', ' ', StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2) continue;
            // Emulators reach the PC directly; only real phones need the tunnel.
            if (parts[0].StartsWith("emulator-")) continue;
            if (parts[1] == "device") ready.Add(parts[0]);
            else if (parts[1] == "unauthorized") unauthorized++;
        }

        foreach (var gone in _tunnels.Where(s => !ready.Contains(s)).ToList())
        {
            _tunnels.Remove(gone);
            _verified.Remove(gone);
            Log.Info($"Android {gone} unplugged");
        }

        foreach (var serial in ready)
        {
            bool known = _tunnels.Contains(serial);
            // Re-check an existing tunnel now and then: an adb server restart drops it silently.
            if (known && _verified.TryGetValue(serial, out var t) && DateTime.UtcNow - t < TimeSpan.FromSeconds(10)) continue;
            if (known)
            {
                var list = Run($"-s {serial} reverse --list");
                if (list != null && list.Contains($"tcp:{_port}"))
                {
                    _verified[serial] = DateTime.UtcNow;
                    continue;
                }
            }
            if (Run($"-s {serial} reverse tcp:{_port} tcp:{_port}") != null)
            {
                _tunnels.Add(serial);
                _verified[serial] = DateTime.UtcNow;
                if (!known) Log.Info($"Android {serial}: USB tunnel to port {_port} is up");
            }
        }

        Devices = _tunnels.Count;
        Unauthorized = unauthorized;
    }

    /// <summary>Runs adb with a timeout; null when it failed.</summary>
    private string? Run(string args)
    {
        try
        {
            var psi = new ProcessStartInfo(AdbPath!, args)
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using var p = Process.Start(psi);
            if (p == null) return null;
            var stdout = p.StandardOutput.ReadToEndAsync();
            var stderr = p.StandardError.ReadToEndAsync();
            if (!p.WaitForExit(8000))
            {
                try { p.Kill(true); } catch { }
                return null;
            }
            return p.ExitCode == 0 ? stdout.Result : null;
        }
        catch (Exception ex)
        {
            Log.Warn($"adb {args}: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// Prefer the Android SDK's adb when one is installed (two different adb versions keep killing
    /// each other's server), then PATH, then the copy shipped with LocalKeys.
    /// </summary>
    private static string? FindAdb()
    {
        var candidates = new List<string>();
        foreach (var env in new[] { "ANDROID_HOME", "ANDROID_SDK_ROOT" })
            if (Environment.GetEnvironmentVariable(env) is { Length: > 0 } sdk)
                candidates.Add(Path.Combine(sdk, "platform-tools", "adb.exe"));
        candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Android", "Sdk", "platform-tools", "adb.exe"));
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try { candidates.Add(Path.Combine(dir.Trim('"'), "adb.exe")); } catch { }
        }
        candidates.Add(Path.Combine(AppContext.BaseDirectory, "adb", "adb.exe"));
        return candidates.FirstOrDefault(File.Exists);
    }

    public void Dispose() => _stopped = true;
}
