import Foundation
import Network

/// One framed TCP connection to the PC — either over Wi-Fi (we connect to the PC)
/// or over USB (the PC connects to us through usbmux).
final class Link {
    enum Kind: String { case wifi, usb }

    let kind: Kind
    let conn: NWConnection
    let label: String

    var onFrame: ((Link, MsgType, [UInt8]) -> Void)?
    var onClose: ((Link) -> Void)?
    var onReady: ((Link) -> Void)?

    private(set) var closed = false
    private(set) var ready = false
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
            guard let self = self else { return }
            switch state {
            case .ready:
                self.ready = true
                self.lastRx = Date()
                self.onReady?(self)
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
        conn.start(queue: .main)
    }

    private func readHeader() {
        conn.receive(minimumIncompleteLength: 2, maximumLength: 2) { [weak self] data, _, isComplete, error in
            guard let self = self, !self.closed else { return }
            if let data = data, data.count == 2 {
                let b = [UInt8](data)
                let len = Int(b[0]) << 8 | Int(b[1])
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
            self.lastRx = Date()
            let bytes = [UInt8](data)
            if let type = MsgType(rawValue: bytes[0]) {
                self.onFrame?(self, type, Array(bytes.dropFirst()))
            }
            if self.closed { return }
            if isComplete || error != nil { self.close(); return }
            self.readHeader()
        }
    }

    func send(_ data: Data) {
        guard !closed, ready else { return }
        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    func close() {
        if closed { return }
        closed = true
        authed = false
        conn.stateUpdateHandler = nil
        conn.cancel()
        onClose?(self)
    }
}
