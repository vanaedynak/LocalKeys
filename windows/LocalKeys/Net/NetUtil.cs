using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;

namespace LocalKeys.Net;

internal sealed record LanInterface(int Index, IPAddress Address, string Name, bool Wireless);

internal static class NetUtil
{
    // Virtual adapters (VPNs, hypervisors, tunnels) must not be advertised: the iPad cannot reach them.
    private static readonly string[] VirtualMarkers =
    {
        "virtual", "vpn", "radmin", "hamachi", "vmware", "virtualbox", "hyper-v", "tap-", "tap ", "tun",
        "wireguard", "zerotier", "tailscale", "loopback", "bluetooth", "npcap", "wintun", "openvpn", "nordlynx",
        "fortinet", "cisco anyconnect", "teredo", "isatap", "wsl", "docker",
    };

    public static List<LanInterface> LanInterfaces()
    {
        var result = new List<LanInterface>();
        try
        {
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up) continue;
                bool wireless = ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211;
                bool wired = ni.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet
                    or NetworkInterfaceType.FastEthernetT or NetworkInterfaceType.FastEthernetFx or NetworkInterfaceType.Ethernet3Megabit;
                if (!wireless && !wired) continue;
                var text = (ni.Description + " " + ni.Name).ToLowerInvariant();
                if (VirtualMarkers.Any(text.Contains)) continue;

                var props = ni.GetIPProperties();
                var v4 = props.GetIPv4Properties();
                if (v4 == null) continue;
                var addr = props.UnicastAddresses
                    .Select(a => a.Address)
                    .FirstOrDefault(a => a.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(a)
                                         && !a.ToString().StartsWith("169.254."));
                if (addr == null) continue;
                result.Add(new LanInterface(v4.Index, addr, ni.Name, wireless));
            }
        }
        catch (Exception ex)
        {
            Log.Error("Enumerate interfaces", ex);
        }
        // Wi-Fi first: that is where the iPad is.
        return result.OrderBy(i => i.Wireless ? 0 : 1).ToList();
    }
}
