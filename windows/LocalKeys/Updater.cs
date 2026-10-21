using System.Diagnostics;
using System.Net.Http.Headers;
using System.Reflection;
using System.Text.Json;
using Timer = System.Threading.Timer;

namespace LocalKeys;

/// <summary>
/// Keeps the agent up to date without user involvement: checks the latest GitHub release and,
/// when it is newer, downloads the installer and runs it silently. The agent runs elevated
/// (scheduled task), so the installer needs no UAC prompt; it stops this process and the
/// installer restarts the agent through the same task.
/// </summary>
internal sealed class Updater : IDisposable
{
    public const string Repo = "vanaedynak/LocalKeys";
    private readonly Config _config;
    private readonly Func<bool> _busyNow;
    private readonly Timer _timer;
    private int _busy;

    public string Status { get; private set; } = "";
    public static Version Current { get; } = Normalize(Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 0, 0));

    public Updater(Config config, Func<bool> busyNow)
    {
        _config = config;
        _busyNow = busyNow;
        // First check shortly after logon, then hourly; installing waits until no iPad is connected.
        _timer = new Timer(_ => _ = CheckAsync(false), null, TimeSpan.FromMinutes(1), TimeSpan.FromHours(1));
    }

    private static Version Normalize(Version v) => new(v.Major, Math.Max(v.Minor, 0), Math.Max(v.Build, 0));

    public async Task<string> CheckAsync(bool manual)
    {
        if (!manual && !_config.AutoUpdate) return Status;
        if (Interlocked.Exchange(ref _busy, 1) == 1) return Status;
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(60) };
            http.DefaultRequestHeaders.UserAgent.Add(new ProductInfoHeaderValue("LocalKeys", Current.ToString()));
            http.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));

            var json = await http.GetStringAsync($"https://api.github.com/repos/{Repo}/releases/latest");
            using var doc = JsonDocument.Parse(json);
            var tag = doc.RootElement.GetProperty("tag_name").GetString() ?? "";
            if (!Version.TryParse(tag.TrimStart('v', 'V'), out var latestRaw))
                return Status = $"Не удалось разобрать версию «{tag}»";
            var latest = Normalize(latestRaw);
            if (latest <= Current)
                return Status = $"Установлена последняя версия ({Current})";

            string? url = null;
            foreach (var a in doc.RootElement.GetProperty("assets").EnumerateArray())
            {
                if (a.GetProperty("name").GetString() == "LocalKeys-Setup.exe")
                    url = a.GetProperty("browser_download_url").GetString();
            }
            if (url == null) return Status = $"В релизе {tag} нет установщика";
            if (!url.StartsWith($"https://github.com/{Repo}/releases/download/", StringComparison.Ordinal))
                return Status = "Неожиданный адрес установщика, обновление пропущено";

            if (!Elevation.IsElevated)
                return Status = $"Доступна версия {latest} — скачайте установщик с GitHub (нет прав для тихой установки)";

            if (!manual && _busyNow())
                return Status = $"Доступна версия {latest}: установится, когда iPad будет отключён";

            Status = $"Загрузка версии {latest}…";
            Log.Info($"Updating {Current} -> {latest} from {url}");
            var path = Path.Combine(Path.GetTempPath(), $"LocalKeys-Setup-{latest}.exe");
            await using (var src = await http.GetStreamAsync(url))
            await using (var dst = File.Create(path))
                await src.CopyToAsync(dst);
            if (new FileInfo(path).Length < 1_000_000)
                return Status = "Загруженный установщик повреждён";

            Process.Start(new ProcessStartInfo(path, "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            return Status = $"Устанавливается версия {latest}…";
        }
        catch (Exception ex)
        {
            Log.Warn($"Update check failed: {ex.Message}");
            return Status = "Не удалось проверить обновления (нет интернета?)";
        }
        finally
        {
            Volatile.Write(ref _busy, 0);
        }
    }

    public void Dispose() => _timer.Dispose();
}
