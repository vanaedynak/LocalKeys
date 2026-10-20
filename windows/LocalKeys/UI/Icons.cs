namespace LocalKeys.UI;

internal static class Icons
{
    private static Icon Load(string name, int size)
    {
        using var s = typeof(Icons).Assembly.GetManifestResourceStream(name);
        return s != null ? new Icon(s, size, size) : SystemIcons.Application;
    }

    public static readonly Icon App = Load("app.ico", 32);
    public static readonly Icon TrayOn = Load("tray_on.ico", 16);
    public static readonly Icon TrayOff = Load("tray_off.ico", 16);
}

internal static class Theme
{
    public static readonly Color Bg = Color.FromArgb(18, 20, 26);
    public static readonly Color Panel = Color.FromArgb(28, 31, 40);
    public static readonly Color PanelBorder = Color.FromArgb(44, 48, 60);
    public static readonly Color Text = Color.FromArgb(232, 235, 242);
    public static readonly Color Dim = Color.FromArgb(150, 156, 172);
    public static readonly Color Accent = Color.FromArgb(94, 129, 255);
    public static readonly Color Good = Color.FromArgb(64, 200, 130);
    public static readonly Color Warn = Color.FromArgb(240, 180, 70);
    public static readonly Color Bad = Color.FromArgb(240, 90, 90);

    public static Font Font(float size, FontStyle style = FontStyle.Regular) => new("Segoe UI", size, style);
}
