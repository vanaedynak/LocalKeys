import Foundation
import Network
import Darwin

/// Fallback discovery for networks where Bonjour/mDNS is blocked (some routers, guest Wi-Fi):
/// probes the local /24 subnet for the LocalKeys port and reads the PC's hello message.
final class NetworkScanner {
    struct Found { let name: String; let host: String }

    private var found: [Found] = []
    private var pending: [UInt32] = []
    private var active: [Link] = []
    private var completion: (([Found]) -> Void)?
    private var finished = false
    private let batchSize = 48

    func scan(completion: @escaping ([Found]) -> Void) {
        self.completion = completion
        guard let (ip, mask) = Self.localIPv4() else { finish(); return }
        let m: UInt32 = mask.nonzeroBitCount >= 24 ? mask : 0xFFFF_FF00
        let net = ip & m
        let bcast = net | ~m
        var h = net &+ 1
        while h < bcast {
            if h != ip { pending.append(h) }
            h &+= 1
        }
        nextBatch()
    }

    func cancel() {
        finished = true
        active.forEach { $0.close() }
        active.removeAll()
    }

    private func nextBatch() {
        guard !finished else { return }
        if pending.isEmpty { finish(); return }
        let batch = pending.prefix(batchSize)
        pending.removeFirst(batch.count)
        for addr in batch { probe(addr) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self, !self.finished else { return }
            self.active.forEach { $0.close() }
            self.active.removeAll()
            // Stop early once something was found and the batch is done.
            if !self.found.isEmpty { self.finish() } else { self.nextBatch() }
        }
    }

    private func probe(_ addr: UInt32) {
        let host = "\(addr >> 24 & 0xFF).\(addr >> 16 & 0xFF).\(addr >> 8 & 0xFF).\(addr & 0xFF)"
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 1
        let params = NWParameters(tls: nil, tcp: tcp)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: Proto.wifiPort)!, using: params)
        let link = Link(kind: .wifi, conn: conn, label: host)
        link.onFrame = { [weak self] l, type, payload in
            guard let self = self else { return }
            if type == .serverHello, let hello = try? JSONDecoder().decode(ServerHello.self, from: Data(payload)) {
                if !self.found.contains(where: { $0.host == host }) {
                    self.found.append(Found(name: hello.pcName, host: host))
                }
            }
            l.close()
        }
        active.append(link)
        link.start()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        active.forEach { $0.close() }
        active.removeAll()
        let result = found
        completion?(result)
        completion = nil
    }

    /// IPv4 address and netmask of the Wi-Fi interface (host byte order).
    static func localIPv4() -> (UInt32, UInt32)? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var fallback: (UInt32, UInt32)?
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let p = ptr {
            let ifa = p.pointee
            ptr = ifa.ifa_next
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), let nm = ifa.ifa_netmask else { continue }
            let name = String(cString: ifa.ifa_name)
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = nm.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if addr >> 16 == 0xA9FE { continue } // 169.254/16 link-local
            if name == "en0" { return (addr, mask) }
            if name.hasPrefix("en") || name.hasPrefix("bridge") { fallback = fallback ?? (addr, mask) }
        }
        return fallback
    }
}
