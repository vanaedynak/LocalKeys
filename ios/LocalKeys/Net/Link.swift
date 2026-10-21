import Foundation
import Network

/// One framed TCP connection to the PC — either over Wi-Fi (we connect to the PC)
/// or over USB (the PC connects to us through usbmux).
///
/// Socket work runs on a dedicated network queue, so a busy or stuck UI thread never delays
/// reading or sending. Events (ready, frames, close) are delivered on the main queue, in order.
final class Link {
    enum Kind: String { case wifi, usb }

    private static let queue = DispatchQueue(label: "localkeys.net", qos: .userInteractive)

    let kind: Kind
    let conn: NWConnection
    let label: String

    var onFrame: ((Link, MsgType, [UInt8]) -> Void)?
    var onClose: ((Link) -> Void)?
    var onReady: ((Link) -> Void)?

    // Shared with the network queue and the freeze watchdog thread.
    private let lock = NSLock()
    private var _closed = false
    private var _ready = false
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return _ready && !_closed }

    // Main-thread state.
    var lastRx = Date()
    var serverHello: ServerHello?
    var authed = false
    var pairingCode: String?
    var denied = false
    var rttMs: Double?

    init(kind: Kind, conn: NWConnection, label: String) {
        self.kind = kind
        self.conn = conn
        self.label = label
    }

    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 4
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        // WMM voice class: highest Wi-Fi priority, lowest queuing latency.
        params.serviceClass = .interactiveVoice
        return params
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.closed else { return }
            switch state {
            case .ready:
                self.lock.lock(); self._ready = true; self.lock.unlock()
                DispatchQueue.main.async {
                    guard !self.closed else { return }
                    self.lastRx = Date()
                    self.onReady?(self)
                }
                self.readHeader()
            case .failed, .cancelled:
                self.close()
            case .waiting:
                // Unreachable right now; let the manager retry with a fresh connection.
                if self.kind == .wifi { self.close() }
            default:
                break
            }
        }
        conn.start(queue: Self.queue)
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, data.count == 2 {
                let len = Int(data[data.startIndex]) << 8 | Int(data[data.startIndex + 1])
                if len == 0 { self.close(); return }
                self.readBody(len)
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.readHeader()
            }
        }
    }

    private func readBody(_ len: Int) {
        conn.receive(minimumIncompleteLength: len, maximumLength: len) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            guard let data = data, data.count == len else {
                self.close()
                return
            }
            let bytes = [UInt8](data)
            if let type = MsgType(rawValue: bytes[0]) {
                let payload = Array(bytes.dropFirst())
                DispatchQueue.main.async {
                    guard !self.closed else { return }
                    self.lastRx = Date()
                    self.onFrame?(self, type, payload)
                }
            } else {
                DispatchQueue.main.async { self.lastRx = Date() }
            }
            if isComplete || error != nil { self.close(); return }
            self.readHeader()
        }
    }

    /// Thread-safe. Failures surface through the connection state (failed/cancelled), so there
    /// is no per-send completion callback to bounce through the main thread on every key.
    func send(_ data: Data) {
        guard ready else { return }
        conn.send(content: data, completion: .idempotent)
    }

    /// Thread-safe; `onClose` is always delivered on the main queue.
    func close() {
        lock.lock()
        if _closed { lock.unlock(); return }
        _closed = true
        lock.unlock()
        conn.cancel()
        let finish = {
            self.authed = false
            self.onClose?(self)
        }
        if Thread.isMainThread { finish() } else { DispatchQueue.main.async(execute: finish) }
    }
}
