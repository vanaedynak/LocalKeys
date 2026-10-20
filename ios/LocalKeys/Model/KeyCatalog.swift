import Foundation

/// Scan codes (PC set 1). High byte 0xE0 marks an extended key. Must match the Windows agent.
enum KC {
    static let esc: UInt16 = 0x01
    static let backspace: UInt16 = 0x0E
    static let tab: UInt16 = 0x0F
    static let enter: UInt16 = 0x1C
    static let lctrl: UInt16 = 0x1D
    static let lshift: UInt16 = 0x2A
    static let rshift: UInt16 = 0x36
    static let lalt: UInt16 = 0x38
    static let space: UInt16 = 0x39
    static let caps: UInt16 = 0x3A
    static let numLock: UInt16 = 0x45
    static let scrollLock: UInt16 = 0x46
    static let rctrl: UInt16 = 0xE01D
    static let ralt: UInt16 = 0xE038
    static let lwin: UInt16 = 0xE05B
    static let rwin: UInt16 = 0xE05C
    static let menu: UInt16 = 0xE05D
    static let home: UInt16 = 0xE047
    static let up: UInt16 = 0xE048
    static let pgUp: UInt16 = 0xE049
    static let left: UInt16 = 0xE04B
    static let right: UInt16 = 0xE04D
    static let end: UInt16 = 0xE04F
    static let down: UInt16 = 0xE050
    static let pgDn: UInt16 = 0xE051
    static let ins: UInt16 = 0xE052
    static let del: UInt16 = 0xE053
    static let prtSc: UInt16 = 0xE037
    static let pause: UInt16 = 0xE145

    static let q: UInt16 = 0x10, w: UInt16 = 0x11, e: UInt16 = 0x12, r: UInt16 = 0x13, t: UInt16 = 0x14
    static let y: UInt16 = 0x15, u: UInt16 = 0x16, i: UInt16 = 0x17, o: UInt16 = 0x18, p: UInt16 = 0x19
    static let a: UInt16 = 0x1E, s: UInt16 = 0x1F, d: UInt16 = 0x20, f: UInt16 = 0x21, g: UInt16 = 0x22
    static let h: UInt16 = 0x23, j: UInt16 = 0x24, k: UInt16 = 0x25, l: UInt16 = 0x26
    static let z: UInt16 = 0x2C, x: UInt16 = 0x2D, c: UInt16 = 0x2E, v: UInt16 = 0x2F, b: UInt16 = 0x30
    static let n: UInt16 = 0x31, m: UInt16 = 0x32

    static func digit(_ n: Int) -> UInt16 { n == 0 ? 0x0B : UInt16(0x01 + n) }

    static func f(_ n: Int) -> UInt16 {
        switch n {
        case 1...10: return UInt16(0x3A + n)
        case 11: return 0x57
        case 12: return 0x58
        case 13...23: return UInt16(0x64 + n - 13)
        case 24: return 0x76
        default: return 0
        }
    }

    static let volMute: UInt16 = 0xE020
    static let volDown: UInt16 = 0xE02E
    static let volUp: UInt16 = 0xE030
    static let playPause: UInt16 = 0xE022
    static let nextTrack: UInt16 = 0xE019
    static let prevTrack: UInt16 = 0xE010
    static let stopMedia: UInt16 = 0xE024
}

enum KeyGroup: String, CaseIterable, Identifiable {
    case letters = "Буквы"
    case symbols = "Цифры и символы"
    case modifiers = "Модификаторы"
    case editing = "Основные"
    case navigation = "Навигация"
    case function = "F-клавиши"
    case numpad = "Цифровой блок"
    case media = "Медиа и система"
    var id: String { rawValue }
}

struct KeyInfo: Identifiable, Hashable {
    let code: UInt16
    let name: String
    let cap: String
    let group: KeyGroup
    var id: UInt16 { code }
}

enum KeyCatalog {
    static let all: [KeyInfo] = build()
    static let byCode: [UInt16: KeyInfo] = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { a, _ in a })

    static let modifierCodes: Set<UInt16> = [KC.lshift, KC.rshift, KC.lctrl, KC.rctrl, KC.lalt, KC.ralt, KC.lwin, KC.rwin]
    static func isModifier(_ c: UInt16) -> Bool { modifierCodes.contains(c) }

    /// Keys whose cap shows characters from the active keyboard layout.
    static let printable: Set<UInt16> = {
        var s: Set<UInt16> = [0x29, 0x2B, 0x56]
        for c in UInt16(0x02)...0x0D { s.insert(c) }
        for c in UInt16(0x10)...0x1B { s.insert(c) }
        for c in UInt16(0x1E)...0x28 { s.insert(c) }
        for c in UInt16(0x2C)...0x35 { s.insert(c) }
        return s
    }()

    static func cap(_ code: UInt16) -> String { byCode[code]?.cap ?? String(format: "%04X", code) }
    static func name(_ code: UInt16) -> String { byCode[code]?.name ?? String(format: "Код %04X", code) }

    private static func build() -> [KeyInfo] {
        var r: [KeyInfo] = []
        func add(_ c: UInt16, _ name: String, _ cap: String? = nil, _ g: KeyGroup) {
            r.append(KeyInfo(code: c, name: name, cap: cap ?? name, group: g))
        }
        for (i, ch) in "QWERTYUIOP".enumerated() { add(UInt16(0x10 + i), String(ch), nil, .letters) }
        for (i, ch) in "ASDFGHJKL".enumerated() { add(UInt16(0x1E + i), String(ch), nil, .letters) }
        for (i, ch) in "ZXCVBNM".enumerated() { add(UInt16(0x2C + i), String(ch), nil, .letters) }

        add(0x29, "` ~ (Ё)", "`", .symbols)
        for n in 1...9 { add(KC.digit(n), "\(n)", nil, .symbols) }
        add(KC.digit(0), "0", nil, .symbols)
        add(0x0C, "- _", "-", .symbols)
        add(0x0D, "= +", "=", .symbols)
        add(0x1A, "[ { (Х)", "[", .symbols)
        add(0x1B, "] } (Ъ/Ї)", "]", .symbols)
        add(0x2B, "\\ |", "\\", .symbols)
        add(0x27, "; : (Ж)", ";", .symbols)
        add(0x28, "' \" (Э/Є)", "'", .symbols)
        add(0x33, ", < (Б)", ",", .symbols)
        add(0x34, ". > (Ю)", ".", .symbols)
        add(0x35, "/ ?", "/", .symbols)
        add(0x56, "ISO \\ |", "\\", .symbols)

        add(KC.lshift, "Левый Shift", "Shift", .modifiers)
        add(KC.rshift, "Правый Shift", "Shift", .modifiers)
        add(KC.lctrl, "Левый Ctrl", "Ctrl", .modifiers)
        add(KC.rctrl, "Правый Ctrl", "Ctrl", .modifiers)
        add(KC.lalt, "Левый Alt", "Alt", .modifiers)
        add(KC.ralt, "Правый Alt (AltGr)", "Alt", .modifiers)
        add(KC.lwin, "Левый Win", "sf:square.grid.2x2.fill", .modifiers)
        add(KC.rwin, "Правый Win", "sf:square.grid.2x2.fill", .modifiers)
        add(KC.menu, "Меню", "sf:filemenu.and.selection", .modifiers)

        add(KC.esc, "Esc", nil, .editing)
        add(KC.tab, "Tab", nil, .editing)
        add(KC.caps, "Caps Lock", "Caps", .editing)
        add(KC.enter, "Enter", nil, .editing)
        add(KC.backspace, "Backspace", "sf:delete.left", .editing)
        add(KC.space, "Пробел", "", .editing)
        add(KC.ins, "Insert", "Ins", .editing)
        add(KC.del, "Delete", "Del", .editing)
        add(KC.prtSc, "Print Screen", "PrtSc", .editing)
        add(KC.scrollLock, "Scroll Lock", "ScrLk", .editing)
        add(KC.pause, "Pause/Break", "Pause", .editing)

        add(KC.home, "Home", nil, .navigation)
        add(KC.end, "End", nil, .navigation)
        add(KC.pgUp, "Page Up", "PgUp", .navigation)
        add(KC.pgDn, "Page Down", "PgDn", .navigation)
        add(KC.up, "Стрелка вверх", "sf:arrowtriangle.up.fill", .navigation)
        add(KC.down, "Стрелка вниз", "sf:arrowtriangle.down.fill", .navigation)
        add(KC.left, "Стрелка влево", "sf:arrowtriangle.left.fill", .navigation)
        add(KC.right, "Стрелка вправо", "sf:arrowtriangle.right.fill", .navigation)

        for n in 1...24 { add(KC.f(n), "F\(n)", nil, .function) }

        add(KC.numLock, "Num Lock", "Num", .numpad)
        add(0xE035, "Num /", "/", .numpad)
        add(0x37, "Num *", "*", .numpad)
        add(0x4A, "Num -", "−", .numpad)
        add(0x4E, "Num +", "+", .numpad)
        add(0xE01C, "Num Enter", "Enter", .numpad)
        add(0x53, "Num .", ".", .numpad)
        add(0x52, "Num 0", "0", .numpad)
        add(0x4F, "Num 1", "1", .numpad)
        add(0x50, "Num 2", "2", .numpad)
        add(0x51, "Num 3", "3", .numpad)
        add(0x4B, "Num 4", "4", .numpad)
        add(0x4C, "Num 5", "5", .numpad)
        add(0x4D, "Num 6", "6", .numpad)
        add(0x47, "Num 7", "7", .numpad)
        add(0x48, "Num 8", "8", .numpad)
        add(0x49, "Num 9", "9", .numpad)

        add(KC.volMute, "Без звука", "sf:speaker.slash.fill", .media)
        add(KC.volDown, "Тише", "sf:speaker.wave.1.fill", .media)
        add(KC.volUp, "Громче", "sf:speaker.wave.3.fill", .media)
        add(KC.playPause, "Пуск/пауза", "sf:playpause.fill", .media)
        add(KC.nextTrack, "Следующий трек", "sf:forward.end.fill", .media)
        add(KC.prevTrack, "Предыдущий трек", "sf:backward.end.fill", .media)
        add(KC.stopMedia, "Стоп", "sf:stop.fill", .media)
        add(0xE021, "Калькулятор", "sf:plus.forwardslash.minus", .media)
        add(0xE032, "Браузер: домой", "sf:house.fill", .media)
        add(0xE06A, "Браузер: назад", "sf:chevron.backward", .media)
        add(0xE069, "Браузер: вперёд", "sf:chevron.forward", .media)
        add(0xE06C, "Почта", "sf:envelope.fill", .media)
        add(0xE06B, "Этот компьютер", "sf:desktopcomputer", .media)
        return r
    }
}
