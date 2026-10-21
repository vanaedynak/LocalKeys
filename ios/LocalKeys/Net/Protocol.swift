import Foundation

/// Wire format: [u16 BE length of (type + payload)] [u8 type] [payload].
/// Must stay in sync with windows/LocalKeys/Protocol.cs.
enum MsgType: UInt8 {
    case serverHello = 0x00
    case hello = 0x01
    case helloAck = 0x02
    case ping = 0x03
    case pong = 0x04
    case keyDown = 0x10
    case keyUp = 0x11
    case stateSync = 0x12
    case releaseAll = 0x13
    case text = 0x14
    case mouseMove = 0x20
    case mouseButton = 0x21
    case scroll = 0x22
    case command = 0x30
    case pcState = 0x40
}

enum Proto {
    static let version = 1
    static let wifiPort: UInt16 = 47810
    static let usbPort: UInt16 = 47811
    static let bonjourType = "_localkeys._tcp"

    static func frame(_ type: MsgType, _ payload: [UInt8] = []) -> Data {
        var d = Data(capacity: payload.count + 3)
        let len = UInt16(payload.count + 1)
        d.append(UInt8(len >> 8))
        d.append(UInt8(len & 0xFF))
        d.append(type.rawValue)
        d.append(contentsOf: payload)
        return d
    }

    static func u16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xFF)] }
    static func i16(_ v: Int) -> [UInt8] { u16(UInt16(bitPattern: Int16(clamping: v))) }

    static func json<T: Encodable>(_ type: MsgType, _ value: T) -> Data {
        let data = (try? JSONEncoder().encode(value)) ?? Data()
        return frame(type, [UInt8](data))
    }

    static func keyDown(_ c: UInt16) -> Data { frame(.keyDown, u16(c)) }
    static func keyUp(_ c: UInt16) -> Data { frame(.keyUp, u16(c)) }
    static func mouseMove(_ dx: Int, _ dy: Int) -> Data { frame(.mouseMove, i16(dx) + i16(dy)) }
    static func mouseButton(_ b: UInt8, _ down: Bool) -> Data { frame(.mouseButton, [b, down ? 1 : 0]) }
    static func scroll(_ v: Int, _ h: Int) -> Data { frame(.scroll, i16(v) + i16(h)) }
    static func text(_ s: String) -> Data { frame(.text, Array(s.utf8.prefix(60000))) }

    static func stateSync(keys: [UInt16], buttons: UInt8) -> Data {
        let list = Array(keys.prefix(255))
        var p: [UInt8] = [UInt8(list.count)]
        for k in list { p += u16(k) }
        p.append(buttons)
        return frame(.stateSync, p)
    }

    static func ping() -> Data {
        var t = DispatchTime.now().uptimeNanoseconds
        let bytes = withUnsafeBytes(of: &t) { Array($0) }
        return frame(.ping, bytes)
    }

    static func pingTime(_ payload: [UInt8]) -> UInt64? {
        guard payload.count == 8 else { return nil }
        var t: UInt64 = 0
        withUnsafeMutableBytes(of: &t) { $0.copyBytes(from: payload) }
        return t
    }
}

struct ServerHello: Codable {
    var v: Int?
    var pcId: String
    var pcName: String
}

struct HelloMsg: Codable {
    var v: Int
    var deviceId: String
    var name: String
    var token: String?
}

struct HelloAck: Codable {
    var status: String
    var token: String?
    var code: String?
    var message: String?
}

struct CommandMsg: Codable {
    var cmd: String
    var arg: String?
}

struct KbLayoutInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var lang: String
}

struct PcState: Codable, Equatable {
    var pcName: String?
    var layoutId: String?
    var lang: String?
    var layoutName: String?
    var layouts: [KbLayoutInfo]?
    var legends: [String: [String]]?
    var caps: Bool?
    var num: Bool?
    var scroll: Bool?
    var elevated: Bool?
    var addresses: [String]?
    var port: Int?
}
