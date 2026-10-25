import Foundation
import Network
import Combine
import UIKit

struct DiscoveredPC: Identifiable, Hashable {
    var id: String { name + "|" + source }
    let name: String
    let endpoint: NWEndpoint
    /// bonjour | scan
    let source: String
}

/// Keeps a USB link and a Wi-Fi link alive at the same time and routes input through the best one:
/// USB when the cable is plugged in, otherwise Wi-Fi. Switching is seamless: the held-keys state
/// is re-synced on the new link, and the PC releases everything that was held through a dead link.
final class ConnectionManager: ObservableObject {
    static let shared = ConnectionManager()

    enum Phase: Equatable {
        case idle, searching, connecting, pairing, denied, connected
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transport: Link.Kind?
    @Published private(set) var pcName: String = ""
    @Published private(set) var rttMs: Int?
    @Published private(set) var pairingCode: String?
    @Published private(set) var pcState: PcState?
    @Published private(set) var discovered: [DiscoveredPC] = []
    @Published private(set) var usbListening = false
    @Published private(set) var usbLinked = false
    @Published private(set) var wifiLinked = false
    @Published private(set) var scanning = false
    @Published private(set) var statusDetail = ""
    /// A known PC has not answered for a while: most likely the LocalKeys program on it isn't running.
    @Published private(set) var pcUnresponsive = false
    private var lostSince: Date?
    /// The user denied "Local Network" access: Wi-Fi discovery and connections cannot work.
    @Published private(set) var localNetworkDenied = false

    private let settings = AppSettings.shared
    private var usbLink: Link? { didSet { publishLinks() } }
    private var wifiLink: Link? { didSet { publishLinks() } }

    /// Links readable off the main thread, for the freeze watchdog.
    private let linksLock = NSLock()
    private var linksSnapshot: [Link] = []
    private func publishLinks() {
        let l = [usbLink, wifiLink].compactMap { $0 }
        linksLock.lock(); linksSnapshot = l; linksLock.unlock()
    }

    /// Called from the watchdog thread while the main thread is stuck: tell the PC to let go now.
    func emergencyReleaseAll() {
        linksLock.lock(); let l = linksSnapshot; linksLock.unlock()
        let frame = Proto.frame(.releaseAll)
        for link in l { link.send(frame) }
    }
    private var lastActive: Link?
    private var browser: NWBrowser?
    private var listener: NWListener?
    private var timer: Timer?
    private var running = false
    private var nextWifiAttempt = Date.distantPast
    private var wifiAttempt = 0
    private var scanFound: [DiscoveredPC] = []
    private var bonjourFound: [DiscoveredPC] = []
    private var scanner: NetworkScanner?
    private var deniedUntil: Date?
    private var lastAutoScan = Date.distantPast
    /// Subnet probing is heavy (hundreds of connections): back off while it finds nothing.
    private var autoScanEvery: TimeInterval = 40
    private var startedAt = Date()
    private var cancellables = Set<AnyCancellable>()

    var activeLink: Link? {
        if let u = usbLink, u.authed { return u }
        if let w = wifiLink, w.authed { return w }
        return nil
    }

    private init() {
        // Reconnect when the user changes connection settings.
        settings.$manualHost.dropFirst().debounce(for: .seconds(0.8), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.reconnectWifi() }.store(in: &cancellables)
        settings.$preferredPC.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.reconnectWifi() }
        }.store(in: &cancellables)
        settings.$wifiEnabled.dropFirst().sink { [weak self] on in
            DispatchQueue.main.async { if !on { self?.wifiLink?.close() }; self?.reconnectWifi() }
        }.store(in: &cancellables)
        settings.$usbEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.restartUSB() }
        }.store(in: &cancellables)
    }

    // MARK: lifecycle

    func start() {
        guard !running else { return }
        running = true
        startedAt = Date()
        startBrowser()
        startUSBListener()
        nextWifiAttempt = Date.distantPast
        timer?.invalidate()
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    /// App goes to background: release everything on the PC and drop links.
    func stop() {
        guard running else { return }
        activeLink?.send(Proto.frame(.releaseAll))
        InputController.shared.resetLocal()
        running = false
        timer?.invalidate()
        timer = nil
        browser?.cancel()
        browser = nil
        listener?.cancel()
        listener = nil
        usbListening = false
        usbLink?.close()
        wifiLink?.close()
        scanner?.cancel()
        refresh()
    }

    func send(_ data: Data) {
        activeLink?.send(data)
    }

    func reconnectWifi() {
        wifiLink?.close()
        wifiAttempt = 0
        nextWifiAttempt = Date.distantPast
        if running { tick() }
    }

    // MARK: discovery

    private func startBrowser() {
        browser?.cancel()
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let b = NWBrowser(for: .bonjour(type: Proto.bonjourType, domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            self.bonjourFound = results.compactMap { r -> DiscoveredPC? in
                if case let .service(name, _, _, _) = r.endpoint {
                    return DiscoveredPC(name: name, endpoint: r.endpoint, source: "bonjour")
                }
                return nil
            }.sorted { $0.name < $1.name }
            self.mergeDiscovered()
            if self.wifiLink == nil { self.nextWifiAttempt = Date.distantPast }
        }
        b.stateUpdateHandler = { [weak self] state in
            if case .waiting(let error) = state, case .dns(let code) = error, code == -65570 /* kDNSServiceErr_PolicyDenied */ {
                self?.localNetworkDenied = true
                self?.refresh()
            }
            if case .ready = state, self?.localNetworkDenied == true {
                self?.localNetworkDenied = false
                self?.refresh()
            }
            if case .failed = state {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    if self?.running == true { self?.startBrowser() }
                }
            }
        }
        b.start(queue: .main)
        browser = b
    }

    private func mergeDiscovered() {
        var list = bonjourFound
        for s in scanFound where !list.contains(where: { $0.name == s.name }) { list.append(s) }
        discovered = list
    }

    func scanNetwork() {
        guard !scanning else { return }
        scanning = true
        let sc = NetworkScanner()
        scanner = sc
        sc.scan { [weak self] found in
            guard let self = self else { return }
            self.scanning = false
            self.scanFound = found.map { DiscoveredPC(name: $0.name, endpoint: .hostPort(host: NWEndpoint.Host($0.host), port: NWEndpoint.Port(rawValue: Proto.wifiPort)!), source: "scan") }
            self.mergeDiscovered()
            if self.wifiLink == nil || self.wifiLink?.authed == false { self.reconnectWifi() }
        }
    }

    // MARK: USB (we are the server; the PC reaches us through usbmux)

    private func restartUSB() {
        listener?.cancel()
        listener = nil
        usbListening = false
        usbLink?.close()
        if running { startUSBListener() }
    }

    private func startUSBListener() {
        guard settings.usbEnabled, listener == nil else { return }
        do {
            let params = Link.tcpParameters()
            params.allowLocalEndpointReuse = true
            params.serviceClass = .responsiveData
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Proto.usbPort)!)
            l.newConnectionHandler = { [weak self] conn in self?.acceptUSB(conn) }
            l.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    self.usbListening = true
                case .failed:
                    self.usbListening = false
                    self.listener?.cancel()
                    self.listener = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        if self.running { self.startUSBListener() }
                    }
                case .cancelled:
                    self.usbListening = false
                default:
                    break
                }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            NSLog("LocalKeys: USB listener failed: \(error)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                if self?.running == true { self?.startUSBListener() }
            }
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return a.isLoopback
        case .ipv6(let a): return a.isLoopback || (a.asIPv4?.isLoopback ?? false)
        case .name(let n, _): return n == "localhost" || n == "127.0.0.1" || n == "::1"
        @unknown default: return false
        }
    }

    private func acceptUSB(_ conn: NWConnection) {
        // usbmux delivers tunnelled connections on the loopback interface. Anything else is
        // a device on the LAN trying to impersonate a PC — refuse it.
        guard Self.isLoopback(conn.endpoint) else {
            NSLog("LocalKeys: rejected non-loopback connection on USB port from \(conn.endpoint)")
            conn.cancel()
            return
        }
        usbLink?.close()
        let link = Link(kind: .usb, conn: conn, label: "USB")
        attach(link)
        usbLink = link
        link.start()
        refresh()
    }

    // MARK: Wi-Fi (we are the client)

    private func wifiCandidates() -> [(NWEndpoint, String)] {
        var list: [(NWEndpoint, String)] = []
        let manual = settings.manualHost.trimmingCharacters(in: .whitespaces)
        if !manual.isEmpty {
            var host = manual
            var port = Proto.wifiPort
            if let idx = manual.lastIndex(of: ":"), !manual.contains("::"), let p = UInt16(manual[manual.index(after: idx)...]) {
                host = String(manual[..<idx])
                port = p
            }
            list.append((.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!), host))
            return list
        }
        let pref = settings.preferredPC
        if !pref.isEmpty, let d = discovered.first(where: { $0.name == pref }) {
            list.append((d.endpoint, d.name))
        }
        for d in discovered where pref.isEmpty || d.name == pref {
            if !list.contains(where: { $0.1 == d.name }) { list.append((d.endpoint, d.name)) }
        }
        var hosts = settings.knownHosts
        if !settings.lastHost.isEmpty, !hosts.contains(settings.lastHost) { hosts.append(settings.lastHost) }
        for h in hosts {
            list.append((.hostPort(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: Proto.wifiPort)!), h))
        }
        return list
    }

    private func connectWifi() {
        let candidates = wifiCandidates()
        guard !candidates.isEmpty else { return }
        let (endpoint, name) = candidates[wifiAttempt % candidates.count]
        wifiAttempt += 1
        let conn = NWConnection(to: endpoint, using: Link.tcpParameters())
        let link = Link(kind: .wifi, conn: conn, label: name)
        attach(link)
        wifiLink = link
        link.start()
        refresh()
    }

    // MARK: link handling

    private func attach(_ link: Link) {
        link.onReady = { [weak self] l in
            guard let self = self else { return }
            if l.kind == .wifi, case let .hostPort(host, _)? = l.conn.currentPath?.remoteEndpoint, case .ipv4 = host {
                self.settings.lastHost = "\(host)"
            }
            self.refresh()
        }
        link.onClose = { [weak self] l in
            guard let self = self else { return }
            if self.usbLink === l { self.usbLink = nil }
            if self.wifiLink === l {
                self.wifiLink = nil
                if l.denied { self.deniedUntil = Date().addingTimeInterval(15) }
                let delay: TimeInterval = l.denied ? 15 : (l.authed || l.serverHello != nil ? 0.5 : min(0.8 * Double(self.wifiAttempt), 3))
                self.nextWifiAttempt = Date().addingTimeInterval(delay)
            }
            self.refresh()
        }
        link.onFrame = { [weak self] l, type, payload in
            self?.handle(l, type, payload)
        }
    }

    private func handle(_ link: Link, _ type: MsgType, _ p: [UInt8]) {
        switch type {
        case .ping:
            link.send(Proto.frame(.pong, p))
        case .pong:
            if let t = Proto.pingTime(p) {
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= t {
                    let ms = Double(now - t) / 1_000_000
                    link.rttMs = link.rttMs.map { $0 * 0.7 + ms * 0.3 } ?? ms
                    refreshRtt()
                }
            }
        case .serverHello:
            guard let msg = try? JSONDecoder().decode(ServerHello.self, from: Data(p)) else { link.close(); return }
            link.serverHello = msg
            let hello = HelloMsg(v: Proto.version, deviceId: settings.deviceId, name: settings.deviceName,
                                 token: settings.token(for: msg.pcId))
            link.send(Proto.json(.hello, hello))
            refresh()
        case .helloAck:
            guard let ack = try? JSONDecoder().decode(HelloAck.self, from: Data(p)) else { return }
            switch ack.status {
            case "ok":
                if let token = ack.token, let pcId = link.serverHello?.pcId { settings.setToken(token, for: pcId) }
                link.pairingCode = nil
                link.authed = true
                wifiAttempt = 0
            case "pending":
                link.pairingCode = ack.code
            default:
                link.denied = true
                link.close()
            }
            refresh()
        case .pcState:
            if let st = try? JSONDecoder().decode(PcState.self, from: Data(p)) {
                if let addrs = st.addresses, !addrs.isEmpty, addrs != settings.knownHosts {
                    settings.knownHosts = addrs
                }
                // Only the active link's PC drives the keycap legends.
                if link === activeLink || activeLink == nil {
                    if st != pcState {
                        pcState = st
                        NotificationCenter.default.post(name: .lkLegendsChanged, object: nil)
                    }
                }
            }
        default:
            break
        }
    }

    func sendCommand(_ cmd: String, _ arg: String? = nil) {
        activeLink?.send(Proto.json(.command, CommandMsg(cmd: cmd, arg: arg)))
    }

    private func tick() {
        guard running else { return }
        let now = Date()
        for l in [usbLink, wifiLink].compactMap({ $0 }) where l.ready {
            if now.timeIntervalSince(l.lastRx) > 4.5 {
                l.close()
                continue
            }
            l.send(Proto.ping())
        }
        // Auto-discovery found nothing and no address is known/working: probe the subnet now and then.
        if settings.wifiEnabled, wifiLink?.authed != true, settings.manualHost.isEmpty, !scanning,
           bonjourFound.isEmpty, now.timeIntervalSince(lastAutoScan) > autoScanEvery, now.timeIntervalSince(startedAt) > 6 {
            lastAutoScan = now
            // USB already carries input: Wi-Fi is only a standby link, so look much less often.
            autoScanEvery = usbLink?.authed == true ? 300 : min(autoScanEvery * 2, 240)
            scanNetwork()
        }
        if wifiLink?.authed == true || !bonjourFound.isEmpty {
            autoScanEvery = 40
        }
        if settings.wifiEnabled, wifiLink == nil, now >= nextWifiAttempt {
            // While USB carries input, still keep a Wi-Fi link warm for instant failover.
            connectWifi()
            if wifiLink == nil { nextWifiAttempt = now.addingTimeInterval(1.5) }
        }
        if settings.usbEnabled && listener == nil { startUSBListener() }
        refresh()
    }

    private func refreshRtt() {
        if let a = activeLink, let r = a.rttMs { setRtt(Int(r.rounded())) }
    }

    private func refresh() {
        let active = activeLink
        if active !== lastActive {
            lastActive = active
            if let a = active {
                // Transport switch (or first connect): make the PC mirror exactly what is held now.
                // The PC tracks held keys per iPad (not per link), so this is all it takes.
                a.send(InputController.shared.stateSyncFrame())
                if let st = pcState, a.serverHello?.pcName != st.pcName { pcState = nil }
                sendCommand("requestState")
            }
        }

        update(\.usbLinked, usbLink?.authed == true)
        update(\.wifiLinked, wifiLink?.authed == true)
        update(\.transport, active?.kind)
        update(\.pcName, active?.serverHello?.pcName ?? usbLink?.serverHello?.pcName ?? wifiLink?.serverHello?.pcName ?? "")
        if let r = active?.rttMs { setRtt(Int(r.rounded())) } else { update(\.rttMs, nil) }

        let pairing = [usbLink, wifiLink].compactMap { $0 }.first { $0.pairingCode != nil && !$0.authed }
        update(\.pairingCode, active == nil ? pairing?.pairingCode : nil)

        let newPhase: Phase
        if !running { newPhase = .idle }
        else if active != nil { newPhase = .connected }
        else if pairingCode != nil { newPhase = .pairing }
        else if let until = deniedUntil, until > Date() { newPhase = .denied }
        else if usbLink != nil || wifiLink != nil { newPhase = .connecting }
        else { newPhase = .searching }
        if newPhase != phase { phase = newPhase }

        if newPhase == .connected || newPhase == .idle || newPhase == .pairing {
            lostSince = nil
        } else if lostSince == nil {
            lostSince = Date()
        }
        let knownPC = !settings.knownHosts.isEmpty || !settings.lastHost.isEmpty
        update(\.pcUnresponsive, knownPC && (lostSince.map { Date().timeIntervalSince($0) > 15 } ?? false))

        if active == nil, pcState != nil {
            pcState = nil
            NotificationCenter.default.post(name: .lkLegendsChanged, object: nil)
        }

        let detail: String
        switch newPhase {
        case .connected:
            let other = active?.kind == .usb ? (wifiLinked ? " · Wi-Fi в резерве" : "") : ""
            detail = "\(active?.kind == .usb ? "USB-кабель" : "Wi-Fi")\(other)"
        case .searching where pcUnresponsive && !localNetworkDenied, .connecting where pcUnresponsive:
            detail = "Компьютер не отвечает. Проверьте, что он включён, в той же сети и в трее есть значок LocalKeys (если нет — запустите LocalKeys из меню Пуск)."
        case .connecting:
            detail = "Подключение к \(wifiLink?.label ?? "ПК")…"
        case .pairing:
            detail = "Подтвердите код на компьютере"
        case .denied:
            detail = "Компьютер отклонил подключение"
        case .searching where localNetworkDenied:
            detail = "Нет доступа к локальной сети: Настройки → LocalKeys → Локальная сеть"
        case .searching:
            detail = discovered.isEmpty ? "Поиск компьютера с LocalKeys…" : "Найдено: \(discovered.map { $0.name }.joined(separator: ", "))"
        case .idle:
            detail = ""
        }
        update(\.statusDetail, detail)
    }

    /// Latency jitters by a millisecond on every pong; only republish real changes.
    private func setRtt(_ v: Int) {
        if let cur = rttMs, abs(cur - v) < 2 { return }
        rttMs = v
    }

    private func update<T: Equatable>(_ kp: ReferenceWritableKeyPath<ConnectionManager, T>, _ value: T) {
        if self[keyPath: kp] != value { self[keyPath: kp] = value }
    }
}

extension Notification.Name {
    static let lkLegendsChanged = Notification.Name("lkLegendsChanged")
    static let lkInputStateChanged = Notification.Name("lkInputStateChanged")
    static let lkStallRecovered = Notification.Name("lkStallRecovered")
}
