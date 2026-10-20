using System.Security.Cryptography;
using System.Text.Json;

namespace LocalKeys;

internal sealed class TrustedDevice
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Token { get; set; } = "";
    public DateTime Added { get; set; } = DateTime.Now;
    public DateTime LastSeen { get; set; } = DateTime.Now;
}

internal sealed class Config
{
    public string PcId { get; set; } = Guid.NewGuid().ToString("N");
    public bool WifiEnabled { get; set; } = true;
    public bool UsbEnabled { get; set; } = true;
    public int WifiPort { get; set; } = Protocol.WifiPort;
    public bool ShowConnectNotifications { get; set; } = true;
    public bool AutoUpdate { get; set; } = true;
    public List<TrustedDevice> Devices { get; set; } = new();

    private static readonly object Gate = new();
    public static readonly string Dir = Environment.GetEnvironmentVariable("LOCALKEYS_DATA_DIR") is { Length: > 0 } custom
        ? custom
        : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "LocalKeys");
    private static readonly string FilePath = Path.Combine(Dir, "config.json");

    private static readonly JsonSerializerOptions JsonOpts = new() { WriteIndented = true };

    public static Config Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var cfg = JsonSerializer.Deserialize<Config>(File.ReadAllText(FilePath), JsonOpts);
                if (cfg != null) return cfg;
            }
        }
        catch (Exception ex)
        {
            Log.Error("Config load failed", ex);
        }
        var fresh = new Config();
        fresh.Save();
        return fresh;
    }

    public void Save()
    {
        lock (Gate)
        {
            try
            {
                Directory.CreateDirectory(Dir);
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(this, JsonOpts));
                File.Move(tmp, FilePath, true);
            }
            catch (Exception ex)
            {
                Log.Error("Config save failed", ex);
            }
        }
    }

    public TrustedDevice? FindTrusted(string id, string? token)
    {
        if (string.IsNullOrEmpty(token)) return null;
        lock (Gate)
        {
            var d = Devices.FirstOrDefault(x => x.Id == id);
            if (d == null) return null;
            var a = System.Text.Encoding.UTF8.GetBytes(d.Token);
            var b = System.Text.Encoding.UTF8.GetBytes(token);
            return CryptographicOperations.FixedTimeEquals(a, b) ? d : null;
        }
    }

    public TrustedDevice Trust(string id, string name)
    {
        TrustedDevice d;
        lock (Gate)
        {
            d = Devices.FirstOrDefault(x => x.Id == id) ?? new TrustedDevice { Id = id };
            if (!Devices.Contains(d)) Devices.Add(d);
            d.Name = name;
            d.Token = Convert.ToHexString(RandomNumberGenerator.GetBytes(32));
            d.LastSeen = DateTime.Now;
        }
        Save();
        return d;
    }

    public void Forget(string id)
    {
        lock (Gate) Devices.RemoveAll(x => x.Id == id);
        Save();
    }

    public List<TrustedDevice> SnapshotDevices()
    {
        lock (Gate) return Devices.ToList();
    }
}
