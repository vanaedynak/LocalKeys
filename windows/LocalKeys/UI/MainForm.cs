using System.Diagnostics;
using LocalKeys.Net;

namespace LocalKeys.UI;

internal sealed class MainForm : Form
{
    private readonly AgentCore _core;
    private readonly Label _status = new();
    private readonly Label _statusSub = new();
    private readonly Label _wifi = new();
    private readonly Label _usb = new();
    private readonly LinkLabel _usbFix = new();
    private readonly Label _android = new();
    private readonly Label _joy = new();
    private readonly LinkLabel _joyGet = new();
    private readonly LinkLabel _itunes = new();
    private readonly ListView _connected = new();
    private readonly ListView _trusted = new();
    private readonly CheckBox _autostart = new();
    private readonly CheckBox _notify = new();
    private readonly Label _updateStatus = new();
    private readonly System.Windows.Forms.Timer _timer = new() { Interval = 1000 };
    private string _lastTrustedSig = "";
    private string _lastConnectedSig = "";

    public MainForm(AgentCore core)
    {
        _core = core;
        Text = "LocalKeys";
        Icon = Icons.App;
        BackColor = Theme.Bg;
        ForeColor = Theme.Text;
        Font = Theme.Font(9.5f);
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(580, 780);
        MinimumSize = new Size(520, 500);
        StartPosition = FormStartPosition.CenterScreen;
        AutoScroll = true;

        var flow = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            Dock = DockStyle.Fill,
            AutoScroll = true,
            Padding = new Padding(16, 12, 16, 16),
        };
        Controls.Add(flow);

        // Header
        var title = new Label { Text = "LocalKeys", Font = Theme.Font(20, FontStyle.Bold), AutoSize = true, Margin = new Padding(0, 0, 0, 2) };
        var subtitle = new Label { Text = "iPad как клавиатура и тачпад для этого компьютера", ForeColor = Theme.Dim, AutoSize = true, Margin = new Padding(2, 0, 0, 12) };
        flow.Controls.Add(title);
        flow.Controls.Add(subtitle);

        // Status card
        _status.Font = Theme.Font(13, FontStyle.Bold);
        _status.AutoSize = true;
        _statusSub.ForeColor = Theme.Dim;
        _statusSub.AutoSize = true;
        _statusSub.MaximumSize = new Size(500, 0);
        flow.Controls.Add(Card("Состояние", _status, _statusSub));

        // Wi-Fi
        _wifi.AutoSize = true;
        _wifi.MaximumSize = new Size(500, 0);
        flow.Controls.Add(Card("Wi-Fi / локальная сеть", _wifi));

        // USB
        _usb.AutoSize = true;
        _usb.MaximumSize = new Size(500, 0);
        _usbFix.AutoSize = true;
        _usbFix.LinkColor = Theme.Accent;
        _usbFix.ActiveLinkColor = Theme.Text;
        _usbFix.Text = "Установить Apple Devices (Microsoft Store)";
        _usbFix.LinkClicked += (_, _) => Open("ms-windows-store://pdp/?ProductId=9NP83LWLPZ9K");
        _itunes.Text = "или iTunes с сайта Apple";
        _itunes.AutoSize = true;
        _itunes.LinkColor = Theme.Accent;
        _itunes.LinkClicked += (_, _) => Open("https://www.apple.com/itunes/download/win64");
        flow.Controls.Add(Card("USB-C кабель", _usb, _usbFix, _itunes));

        _android.AutoSize = true;
        _android.MaximumSize = new Size(500, 0);
        flow.Controls.Add(Card("Android по кабелю", _android));

        _joy.AutoSize = true;
        _joy.MaximumSize = new Size(500, 0);
        _joyGet.AutoSize = true;
        _joyGet.LinkColor = Theme.Accent;
        _joyGet.ActiveLinkColor = Theme.Text;
        _joyGet.Text = "Скачать vJoy (бесплатно)";
        _joyGet.LinkClicked += (_, _) => Open("https://github.com/BrunnerInnovation/vJoy/releases");
        flow.Controls.Add(Card("Джойстик для игр (DCS и др.)", _joy, _joyGet));

        // Connected
        SetupList(_connected, ("Устройство", 170), ("Канал", 80), ("Адрес", 130), ("С", 110));
        _connected.Height = 110;
        flow.Controls.Add(Card("Активные подключения", _connected));

        // Trusted
        SetupList(_trusted, ("Устройство", 220), ("Сопряжено", 130), ("Последний раз", 130));
        _trusted.Height = 120;
        var forget = FlatButton("Забыть выбранное");
        forget.Click += (_, _) =>
        {
            foreach (ListViewItem it in _trusted.SelectedItems)
                _core.ForgetDevice((string)it.Tag!);
            _lastTrustedSig = "";
            Refresh2();
        };
        flow.Controls.Add(Card("Доверенные устройства", _trusted, forget));

        // Options
        _autostart.Text = "Запускать вместе с Windows (в фоне, с правами для игр)";
        _autostart.AutoSize = true;
        _autostart.Checked = Autostart.IsEnabled();
        _autostart.CheckedChanged += (_, _) =>
        {
            if (_autostart.Checked) Autostart.Enable(); else Autostart.Disable();
        };
        _notify.Text = "Уведомлять о подключении iPad";
        _notify.AutoSize = true;
        _notify.Checked = _core.Config.ShowConnectNotifications;
        _notify.CheckedChanged += (_, _) => { _core.Config.ShowConnectNotifications = _notify.Checked; _core.Config.Save(); };
        var logs = FlatButton("Открыть журнал");
        logs.Click += (_, _) => Open(Log.Dir);
        var release = FlatButton("Отпустить все клавиши");
        release.Click += (_, _) => _core.ReleaseEverything();
        var autoUpdate = new CheckBox
        {
            Text = "Обновляться автоматически (тихо, в фоне)",
            AutoSize = true,
            Checked = _core.Config.AutoUpdate,
        };
        autoUpdate.CheckedChanged += (_, _) => { _core.Config.AutoUpdate = autoUpdate.Checked; _core.Config.Save(); };
        var checkUpdate = FlatButton("Проверить обновления");
        checkUpdate.Click += async (_, _) =>
        {
            checkUpdate.Enabled = false;
            _updateStatus.Text = "Проверка…";
            _updateStatus.Text = await _core.Updater.CheckAsync(true);
            checkUpdate.Enabled = true;
        };
        _updateStatus.AutoSize = true;
        _updateStatus.ForeColor = Theme.Dim;
        var buttons = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, Margin = new Padding(0, 6, 0, 0) };
        buttons.Controls.Add(logs);
        buttons.Controls.Add(release);
        buttons.Controls.Add(checkUpdate);
        flow.Controls.Add(Card("Параметры", _autostart, _notify, autoUpdate, buttons, _updateStatus));

        var version = new Label
        {
            Text = $"Версия {Application.ProductVersion.Split('+')[0]} · окно можно закрыть, LocalKeys продолжит работать в трее",
            ForeColor = Theme.Dim,
            AutoSize = true,
            Margin = new Padding(2, 6, 0, 0),
        };
        flow.Controls.Add(version);

        _timer.Tick += (_, _) => Refresh2();
        _timer.Start();
        Refresh2();
    }

    private static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); }
        catch (Exception ex) { Log.Error("Open " + target, ex); }
    }

    private static Button FlatButton(string text)
    {
        var b = new Button
        {
            Text = text,
            AutoSize = true,
            FlatStyle = FlatStyle.Flat,
            BackColor = Theme.PanelBorder,
            ForeColor = Theme.Text,
            Padding = new Padding(8, 3, 8, 3),
            Margin = new Padding(0, 6, 8, 0),
            Cursor = Cursors.Hand,
        };
        b.FlatAppearance.BorderColor = Theme.PanelBorder;
        return b;
    }

    private static void SetupList(ListView lv, params (string name, int width)[] cols)
    {
        lv.View = View.Details;
        lv.FullRowSelect = true;
        lv.HeaderStyle = ColumnHeaderStyle.Nonclickable;
        lv.BackColor = Theme.Bg;
        lv.ForeColor = Theme.Text;
        lv.BorderStyle = BorderStyle.None;
        lv.Width = 510;
        foreach (var (name, width) in cols) lv.Columns.Add(name, width);
        lv.OwnerDraw = true;
        lv.DrawColumnHeader += (_, e) =>
        {
            using var bg = new SolidBrush(Theme.PanelBorder);
            e.Graphics.FillRectangle(bg, e.Bounds);
            TextRenderer.DrawText(e.Graphics, e.Header?.Text, Theme.Font(9f, FontStyle.Bold), e.Bounds with { X = e.Bounds.X + 4 },
                Theme.Dim, TextFormatFlags.VerticalCenter | TextFormatFlags.Left);
        };
        lv.DrawItem += (_, e) => e.DrawDefault = true;
        lv.DrawSubItem += (_, e) => e.DrawDefault = true;
    }

    private static Panel Card(string header, params Control[] content)
    {
        var card = new FlowLayoutPanel
        {
            FlowDirection = FlowDirection.TopDown,
            WrapContents = false,
            AutoSize = true,
            AutoSizeMode = AutoSizeMode.GrowAndShrink,
            BackColor = Theme.Panel,
            Padding = new Padding(14, 10, 14, 12),
            Margin = new Padding(0, 0, 0, 10),
            MinimumSize = new Size(540, 0),
        };
        card.Controls.Add(new Label
        {
            Text = header.ToUpperInvariant(),
            Font = Theme.Font(8.5f, FontStyle.Bold),
            ForeColor = Theme.Dim,
            AutoSize = true,
            Margin = new Padding(0, 0, 0, 6),
        });
        foreach (var c in content) card.Controls.Add(c);
        return card;
    }

    private void Refresh2()
    {
        var sessions = _core.Sessions();
        var authed = sessions.Where(s => s.Authed).ToList();

        if (authed.Count > 0)
        {
            var usb = authed.Any(s => s.Cable);
            _status.Text = usb ? "Подключено по USB" : "Подключено по Wi-Fi";
            _status.ForeColor = Theme.Good;
        }
        else
        {
            _status.Text = "Ожидание iPad / телефона";
            _status.ForeColor = Theme.Warn;
        }
        _statusSub.Text = Elevation.IsElevated
            ? "Работает с правами администратора: ввод доходит до игр и окон, запущенных от администратора."
            : "Работает без прав администратора: в окна/игры, запущенные от администратора, ввод не дойдёт. " +
              "Переустановите LocalKeys или включите автозапуск, запустив программу от имени администратора.";
        _statusSub.ForeColor = Elevation.IsElevated ? Theme.Dim : Theme.Warn;

        var wifi = _core.Wifi;
        var ips = WifiServer.LocalAddresses();
        if (wifi == null) _wifi.Text = "Выключено.";
        else if (wifi.Listening)
            _wifi.Text = $"Готов, порт {_core.Config.WifiPort}. Автопоиск (Bonjour): {(wifi.Advertised ? "включён (" + wifi.AdvertisedOn + ")" : "недоступен — iPad найдёт ПК сканированием сети")}.\n" +
                         $"Адреса этого ПК: {(ips.Count > 0 ? string.Join(", ", ips) : "нет сети")}";
        else _wifi.Text = $"Ошибка: {wifi.Error}";

        var usbc = _core.Usb;
        if (usbc == null)
        {
            _usb.Text = "Выключено.";
            _usbFix.Visible = false;
            _itunes.Visible = false;
        }
        else if (usbc.ServiceAvailable)
        {
            _usb.Text = usbc.UsbDevices > 0
                ? $"Служба Apple найдена. iPad по кабелю: {usbc.UsbDevices}. Откройте LocalKeys на iPad — подключение произойдёт автоматически."
                : "Служба Apple найдена. Подключите iPad кабелем и нажмите «Доверять этому компьютеру» на iPad.";
            _usb.ForeColor = Theme.Text;
            _usbFix.Visible = false;
            _itunes.Visible = false;
        }
        else
        {
            _usb.Text = "Для работы по кабелю нужна служба Apple Mobile Device (бесплатно, ставится один раз вместе с приложением Apple Devices или iTunes). Wi-Fi работает и без неё.";
            _usb.ForeColor = Theme.Warn;
            _usbFix.Visible = true;
            _itunes.Visible = true;
        }

        var adb = _core.Adb;
        if (adb == null) _android.Text = "Выключено.";
        else if (adb.AdbPath == null) _android.Text = "Не найден adb: переустановите LocalKeys. Wi-Fi работает и без него.";
        else if (adb.Devices > 0) _android.Text = $"Телефонов по кабелю: {adb.Devices}. Откройте LocalKeys на телефоне — подключение произойдёт само.";
        else if (adb.Unauthorized > 0) _android.Text = "Телефон подключён: разрешите отладку по USB на его экране (отметьте «Всегда разрешать»).";
        else _android.Text = "Включите на телефоне «Отладку по USB» (режим разработчика) и подключите кабель.";
        _android.ForeColor = adb?.Unauthorized > 0 ? Theme.Warn : Theme.Text;

        var joy = _core.Joystick;
        _joy.Text = joy.Status switch
        {
            "ok" => $"Виртуальный джойстик vJoy готов ({joy.ButtonCount} кнопок). В игре он называется «vJoy Device»: назначьте оси и кнопки в настройках управления.",
            "busy" => "vJoy занят другой программой (например, другим эмулятором джойстика). Закройте её.",
            "error" => "vJoy установлен, но не отвечает. Перезагрузите ПК после установки драйвера.",
            _ => "Для раскладки «DCS / джойстик» на iPad установите бесплатный драйвер vJoy (один раз, потом перезагрузите ПК).",
        };
        _joy.ForeColor = joy.Status == "ok" ? Theme.Text : Theme.Warn;
        _joyGet.Visible = joy.Status != "ok";

        var connSig = string.Join("|", authed.Select(s => s.GetHashCode()));
        if (connSig != _lastConnectedSig)
        {
            _lastConnectedSig = connSig;
            _connected.BeginUpdate();
            _connected.Items.Clear();
            foreach (var s in authed)
                _connected.Items.Add(new ListViewItem(new[]
                {
                    s.DeviceName ?? "?", s.Cable ? "USB" : "Wi-Fi", s.Remote, s.Connected.ToString("HH:mm:ss"),
                }));
            _connected.EndUpdate();
        }

        var devices = _core.Config.SnapshotDevices();
        var sig = string.Join("|", devices.Select(d => d.Id + d.Name + d.LastSeen.Ticks));
        if (sig != _lastTrustedSig)
        {
            _lastTrustedSig = sig;
            _trusted.BeginUpdate();
            _trusted.Items.Clear();
            foreach (var d in devices)
                _trusted.Items.Add(new ListViewItem(new[] { d.Name, d.Added.ToString("dd.MM.yyyy"), d.LastSeen.ToString("dd.MM HH:mm") }) { Tag = d.Id });
            _trusted.EndUpdate();
        }
    }

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        int on = 1;
        try { DwmSetWindowAttribute(Handle, 20 /* DWMWA_USE_IMMERSIVE_DARK_MODE */, ref on, sizeof(int)); } catch { }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        _timer.Stop();
        base.OnFormClosing(e);
    }
}
