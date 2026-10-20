using System.Diagnostics;
using LocalKeys.UI;

namespace LocalKeys;

internal static class Launcher
{
    /// <summary>Asks a running agent (possibly elevated) to open its window, via the loopback socket.</summary>
    public static bool RequestShow(int port, int attempts)
    {
        for (int i = 0; i < attempts; i++)
        {
            try
            {
                using var c = new System.Net.Sockets.TcpClient();
                c.Connect(System.Net.IPAddress.Loopback, port);
                var st = c.GetStream();
                st.Write(new byte[] { 0, 1, Protocol.ShowUi });
                st.Flush();
                Thread.Sleep(100);
                return true;
            }
            catch
            {
                Thread.Sleep(250);
            }
        }
        return false;
    }
}

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--install")) return Setup.Install();
        if (args.Contains("--uninstall")) return Setup.Uninstall();

        bool autostart = args.Contains("--autostart");

        // A manual launch (Start menu) is not elevated: hand over to the elevated scheduled task
        // and ask the elevated agent to show its window.
        if (!Elevation.IsElevated && !args.Contains("--no-elevate") && Autostart.TaskExists())
        {
            int port = Config.Load().WifiPort;
            if (Launcher.RequestShow(port, 1)) return 0;
            if (Autostart.RunTask())
            {
                Launcher.RequestShow(port, 20);
                return 0;
            }
        }

        Mutex mutex;
        bool created;
        try
        {
            mutex = new Mutex(true, @"Local\LocalKeysAgent", out created);
        }
        catch (UnauthorizedAccessException)
        {
            return 0; // an elevated instance is already running
        }
        var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\LocalKeysShow", out _);
        if (!created)
        {
            showEvent.Set();
            return 0;
        }

        try
        {
            Native.timeBeginPeriod(1); // tighter timers for key auto-repeat
            Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.AboveNormal;
        }
        catch { }

        Log.Info($"LocalKeys {Application.ProductVersion} starting (elevated={Elevation.IsElevated}, autostart={autostart})");

        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => Log.Error("UI exception", e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Error("Unhandled", e.ExceptionObject as Exception);

        var config = Config.Load();
        using var core = new AgentCore(config);
        core.Start();

        using var app = new TrayApp(core, showEvent, showWindow: !autostart);
        Application.Run(app);

        core.ReleaseEverything();
        GC.KeepAlive(mutex);
        return 0;
    }
}
