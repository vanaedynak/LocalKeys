namespace LocalKeys.UI;

internal sealed class PairingForm : Form
{
    public bool Allowed { get; private set; }

    public PairingForm(PairingRequest req)
    {
        Text = "LocalKeys — новое устройство";
        Icon = Icons.App;
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        TopMost = true;
        BackColor = Theme.Bg;
        ForeColor = Theme.Text;
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(420, 250);
        ShowInTaskbar = true;

        var title = new Label
        {
            Text = $"«{req.DeviceName}» хочет подключиться",
            Font = Theme.Font(13, FontStyle.Bold),
            AutoSize = false,
            Location = new Point(20, 18),
            Size = new Size(380, 30),
        };
        var hint = new Label
        {
            Text = $"Адрес: {req.Session.Remote}. Убедитесь, что на iPad показан тот же код:",
            Font = Theme.Font(9.5f),
            ForeColor = Theme.Dim,
            AutoSize = false,
            Location = new Point(20, 52),
            Size = new Size(380, 40),
        };
        var code = new Label
        {
            Text = req.Code[..3] + " " + req.Code[3..],
            Font = new Font("Consolas", 30, FontStyle.Bold),
            ForeColor = Theme.Accent,
            TextAlign = ContentAlignment.MiddleCenter,
            Location = new Point(20, 95),
            Size = new Size(380, 60),
        };
        var allow = MakeButton("Разрешить", Theme.Accent, new Point(20, 180));
        allow.Click += (_, _) => { Allowed = true; Close(); };
        var deny = MakeButton("Отклонить", Theme.Panel, new Point(215, 180));
        deny.Click += (_, _) => { Allowed = false; Close(); };

        Controls.AddRange(new Control[] { title, hint, code, allow, deny });
        AcceptButton = allow;
        CancelButton = deny;
    }

    private static Button MakeButton(string text, Color color, Point at)
    {
        var b = new Button
        {
            Text = text,
            Location = at,
            Size = new Size(185, 44),
            FlatStyle = FlatStyle.Flat,
            BackColor = color,
            ForeColor = Theme.Text,
            Font = Theme.Font(10.5f, FontStyle.Bold),
            Cursor = Cursors.Hand,
        };
        b.FlatAppearance.BorderColor = Theme.PanelBorder;
        return b;
    }
}
