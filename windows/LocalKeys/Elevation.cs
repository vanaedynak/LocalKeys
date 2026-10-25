using System.Diagnostics;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32;

namespace LocalKeys;

internal static class Elevation
{
    public static readonly bool IsElevated = Check();

    private static bool Check()
    {
        try
        {
            using var id = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(id).IsInRole(WindowsBuiltInRole.Administrator);
        }
        catch { return false; }
    }
}

/// <summary>
/// Autostart through a Task Scheduler logon task with "highest privileges": the agent starts
/// elevated without a UAC prompt, so it can also type into elevated windows and games
/// (Windows blocks input from a normal process into an elevated one — UIPI).
/// Falls back to the HKCU Run key when not elevated.
/// </summary>
internal static class Autostart
{
    public const string TaskName = "LocalKeys";
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static string ExePath => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "LocalKeys.exe");

    private static (int code, string output) Schtasks(string args)
    {
        try
        {
            var psi = new ProcessStartInfo("schtasks.exe", args)
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            using var p = Process.Start(psi)!;
            var output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            p.WaitForExit(15000);
            return (p.ExitCode, output);
        }
        catch (Exception ex)
        {
            return (-1, ex.Message);
        }
    }

    public static bool TaskExists() => Schtasks($"/Query /TN \"{TaskName}\"").code == 0;

    public static bool RunTask() => Schtasks($"/Run /TN \"{TaskName}\"").code == 0;

    public static bool IsEnabled()
    {
        if (TaskExists()) return true;
        using var k = Registry.CurrentUser.OpenSubKey(RunKey);
        return k?.GetValue(TaskName) != null;
    }

    public static bool Enable()
    {
        if (Elevation.IsElevated && CreateTask())
        {
            RemoveRunKey();
            return true;
        }
        try
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            k.SetValue(TaskName, $"\"{ExePath}\" --autostart");
            return true;
        }
        catch (Exception ex)
        {
            Log.Error("Run key", ex);
            return false;
        }
    }

    public static void Disable()
    {
        if (TaskExists()) Schtasks($"/Delete /TN \"{TaskName}\" /F");
        RemoveRunKey();
    }

    private static void RemoveRunKey()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey, true);
            k?.DeleteValue(TaskName, false);
        }
        catch { }
    }

    private static string Esc(string s) => System.Security.SecurityElement.Escape(s) ?? s;

    /// <summary>
    /// r2: self-healing. If the agent gets killed (Task Manager, "optimizer" tools...), it comes
    /// back by itself: restart on failure after 1 minute, a 5-minute keep-alive and on unlock.
    /// A running agent ignores these (single instance).
    /// </summary>
    private const string TaskRevision = "r2";

    /// <summary>Re-registers a task created by an older version (elevated agent, at startup).</summary>
    public static void UpgradeTaskIfNeeded()
    {
        if (!Elevation.IsElevated) return;
        var (code, output) = Schtasks($"/Query /TN \"{TaskName}\" /XML");
        if (code != 0 || output.Contains($"({TaskRevision})")) return;
        Log.Info(CreateTask() ? "Autostart task upgraded (self-restart enabled)" : "Autostart task upgrade failed");
    }

    // "Exit" from the tray must keep the agent closed until the next sign-in, even with the
    // keep-alive trigger. HKCU\Volatile Environment is wiped by Windows at every sign-out.
    private const string VolatileKey = "Volatile Environment";
    private const string ExitedValue = "LocalKeysUserExit";

    public static void MarkUserExit(bool exited)
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(VolatileKey, true);
            if (exited) k?.SetValue(ExitedValue, "1");
            else k?.DeleteValue(ExitedValue, false);
        }
        catch { }
    }

    public static bool UserExited()
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(VolatileKey);
            return k?.GetValue(ExitedValue) != null;
        }
        catch { return false; }
    }

    public static bool CreateTask()
    {
        string user;
        using (var id = WindowsIdentity.GetCurrent()) user = id.Name;
        var xml = $@"<?xml version=""1.0"" encoding=""UTF-16""?>
<Task version=""1.2"" xmlns=""http://schemas.microsoft.com/windows/2004/02/mit/task"">
  <RegistrationInfo>
    <Description>LocalKeys: iPad keyboard and trackpad agent ({TaskRevision})</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>{Esc(user)}</UserId>
      <Delay>PT2S</Delay>
      <Repetition>
        <Interval>PT5M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </LogonTrigger>
    <SessionStateChangeTrigger>
      <Enabled>true</Enabled>
      <StateChange>SessionUnlock</StateChange>
      <UserId>{Esc(user)}</UserId>
    </SessionStateChangeTrigger>
  </Triggers>
  <Principals>
    <Principal id=""Author"">
      <UserId>{Esc(user)}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>4</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context=""Author"">
    <Exec>
      <Command>{Esc(ExePath)}</Command>
      <Arguments>--autostart</Arguments>
    </Exec>
  </Actions>
</Task>";
        var tmp = Path.Combine(Path.GetTempPath(), "localkeys-task.xml");
        try
        {
            File.WriteAllText(tmp, xml, Encoding.Unicode);
            var (code, output) = Schtasks($"/Create /TN \"{TaskName}\" /XML \"{tmp}\" /F");
            if (code != 0) Log.Warn($"schtasks create failed ({code}): {output}");
            return code == 0;
        }
        finally
        {
            try { File.Delete(tmp); } catch { }
        }
    }
}

/// <summary>Actions run by the installer (elevated): firewall rule + autostart task.</summary>
internal static class Setup
{
    private const string RuleName = "LocalKeys";

    private static int Netsh(string args)
    {
        try
        {
            var psi = new ProcessStartInfo("netsh.exe", args) { CreateNoWindow = true, UseShellExecute = false };
            using var p = Process.Start(psi)!;
            p.WaitForExit(15000);
            return p.ExitCode;
        }
        catch { return -1; }
    }

    public static int Install()
    {
        Log.Info("Setup: install");
        Netsh($"advfirewall firewall delete rule name=\"{RuleName}\"");
        Netsh($"advfirewall firewall add rule name=\"{RuleName}\" dir=in action=allow program=\"{Autostart.ExePath}\" enable=yes profile=any protocol=TCP");
        Netsh($"advfirewall firewall add rule name=\"{RuleName}\" dir=in action=allow program=\"{Autostart.ExePath}\" enable=yes profile=any protocol=UDP");
        if (!Autostart.CreateTask()) Autostart.Enable();
        return 0;
    }

    public static int Uninstall()
    {
        Log.Info("Setup: uninstall");
        Netsh($"advfirewall firewall delete rule name=\"{RuleName}\"");
        Autostart.Disable();
        return 0;
    }
}
