using System.Diagnostics;
using LocalKeys.UI;

namespace LocalKeys;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Contains("--install")) return Setup.Install();
        if (args.Contains("--uninstall")) return Setup.Uninstall();

        bool autostart = args.Contains("--autostart");

        // A manual launch (Start menu) is not elevated: hand over to the elevated scheduled task.
        if (!Elevation.IsElevated && !args.Contains("--no-elevate") && Autostart.TaskExists())
        {
            if (Autostart.RunTask()) return 0;
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
