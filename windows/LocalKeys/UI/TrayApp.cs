using LocalKeys.Net;

namespace LocalKeys.UI;

internal sealed class TrayApp : ApplicationContext
{
    private readonly AgentCore _core;
    private readonly NotifyIcon _tray;
    private readonly SynchronizationContext _ui;
    private readonly ToolStripMenuItem _statusItem;
    private readonly ToolStripMenuItem _autostartItem;
    private MainForm? _main;
    private readonly Dictionary<PairingRequest, PairingForm> _pairingForms = new();
    private readonly RegisteredWaitHandle _showWait;
    private readonly System.Windows.Forms.Timer _timer;

    public TrayApp(AgentCore core, EventWaitHandle showEvent, bool showWindow)
    {
        _core = core;
        // Make sure a WindowsFormsSynchronizationContext exists before capturing it.
        using (new Control()) { }
        _ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();

        _statusItem = new ToolStripMenuItem("LocalKeys") { Enabled = false };
        _autostartItem = new ToolStripMenuItem("Запускать вместе с Windows", null, (_, _) => ToggleAutostart());
        var menu = new ContextMenuStrip();
        menu.Items.Add(_statusItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Открыть LocalKeys", null, (_, _) => ShowMain()));
        menu.Items.Add(_autostartItem);
        menu.Items.Add(new ToolStripMenuItem("Отпустить все клавиши", null, (_, _) => _core.ReleaseEverything()));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Выход", null, (_, _) => ExitThread()));
        menu.Opening += (_, _) => _autostartItem.Checked = Autostart.IsEnabled();

        _tray = new NotifyIcon
        {
            Icon = Icons.TrayOff,
            Text = "LocalKeys",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ShowMain(); };

        _core.PairingRequested += req => _ui.Post(_ => ShowPairing(req), null);
        _core.PairingCancelled += req => _ui.Post(_ => ClosePairing(req), null);
        _core.DeviceConnected += s => _ui.Post(_ => OnDeviceConnected(s), null);
        _core.ShowRequested += () => _ui.Post(_ => ShowMain(), null);

        _showWait = ThreadPool.RegisterWaitForSingleObject(showEvent, (_, _) => _ui.Post(_ => ShowMain(), null), null, -1, false);

        _timer = new System.Windows.Forms.Timer { Interval = 1000 };
        _timer.Tick += (_, _) => UpdateStatus();
        _timer.Start();
        UpdateStatus();

        if (showWindow) ShowMain();
    }

    private void UpdateStatus()
    {
        var authed = _core.Sessions().Where(s => s.Authed).ToList();
        string text;
        if (authed.Count == 0)
        {
            text = "Ожидание iPad";
            _tray.Icon = Icons.TrayOff;
        }
        else
        {
            var names = authed.GroupBy(s => s.DeviceId).Select(g =>
            {
                var best = g.OrderBy(s => s.Transport == Transport.Usb ? 0 : 1).First();
                return $"{best.DeviceName} ({(best.Transport == Transport.Usb ? "USB" : "Wi-Fi")})";
            });
            text = "Подключено: " + string.Join(", ", names);
            _tray.Icon = Icons.TrayOn;
        }
        _statusItem.Text = text;
        var tip = "LocalKeys — " + text;
        _tray.Text = tip.Length > 63 ? tip[..63] : tip;
    }

    private void OnDeviceConnected(Session s)
    {
        UpdateStatus();
        if (!_core.Config.ShowConnectNotifications) return;
        // Do not spam: only notify when this device had no other live link.
        int links = _core.Sessions().Count(x => x.Authed && x.DeviceId == s.DeviceId);
        if (links > 1) return;
        _tray.ShowBalloonTip(2500, "LocalKeys",
            $"{s.DeviceName} подключён по {(s.Transport == Transport.Usb ? "USB" : "Wi-Fi")}", ToolTipIcon.None);
    }

    private void ToggleAutostart()
    {
        if (Autostart.IsEnabled()) Autostart.Disable();
        else Autostart.Enable();
        _autostartItem.Checked = Autostart.IsEnabled();
    }

    public void ShowMain()
    {
        if (_main == null || _main.IsDisposed)
        {
            _main = new MainForm(_core);
        }
        _main.Show();
        if (_main.WindowState == FormWindowState.Minimized) _main.WindowState = FormWindowState.Normal;
        _main.Activate();
        _main.BringToFront();
    }

    private void ShowPairing(PairingRequest req)
    {
        var f = new PairingForm(req);
        _pairingForms[req] = f;
        f.FormClosed += (_, _) =>
        {
            _pairingForms.Remove(req);
            _core.ResolvePairing(req, f.Allowed);
        };
        f.Show();
        f.Activate();
    }

    private void ClosePairing(PairingRequest req)
    {
        if (_pairingForms.TryGetValue(req, out var f) && !f.IsDisposed) f.Close();
    }

    protected override void ExitThreadCore()
    {
        _timer.Stop();
        _showWait.Unregister(null);
        _tray.Visible = false;
        _tray.Dispose();
        _main?.Dispose();
        base.ExitThreadCore();
    }
}
