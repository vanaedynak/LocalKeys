import Foundation

/// Small DSL for laying keys out row by row in key units (1u = one standard key).
private struct LB {
    var keys: [KeyDef] = []
    var x: Double = 0
    var y: Double = 0
    var h: Double = 1

    mutating func row(_ y: Double, h: Double = 1, x: Double = 0) {
        self.y = y; self.h = h; self.x = x
    }

    mutating func k(_ code: UInt16, _ w: Double = 1, _ label: String? = nil, _ style: KeyStyle = .auto) {
        a(.key(code), w, label, style)
    }

    mutating func a(_ action: KeyAction, _ w: Double = 1, _ label: String? = nil, _ style: KeyStyle = .auto, toggle: Bool = false) {
        keys.append(KeyDef(x: x, y: y, w: w, h: h, action: action, label: label, toggle: toggle, style: style))
        x += w
    }

    mutating func gap(_ w: Double) { x += w }

    /// Adds a key with a second action on the Fn layer.
    mutating func kf(_ code: UInt16, _ w: Double = 1, fn: KeyAction?, _ style: KeyStyle = .auto) {
        keys.append(KeyDef(x: x, y: y, w: w, h: h, action: .key(code), style: style, fn: fn))
        x += w
    }

    mutating func put(_ action: KeyAction, _ x: Double, _ y: Double, _ w: Double, _ h: Double,
                      _ label: String? = nil, _ style: KeyStyle = .auto, toggle: Bool = false) {
        keys.append(KeyDef(x: x, y: y, w: w, h: h, action: action, label: label, toggle: toggle, style: style))
    }

    mutating func letters(_ codes: ClosedRange<UInt16>) {
        for c in codes { k(c) }
    }
}

enum BuiltinLayouts {
    static var all: [KBLayout] { [laptop, full, darkProject68, gaming, gamingStick, trackpad, numpad, shortcuts] }

    /// 65% / 68 keys, modelled after Dark Project 68 Sunrise (ANSI): no F-row and no nav cluster,
    /// right column `~ / Del / PgUp / PgDn, arrows; F1–F12 and media on the Fn layer.
    static var darkProject68: KBLayout {
        var b = LB()
        b.row(0)
        b.k(KC.esc)
        for n in 1...9 { b.kf(KC.digit(n), fn: .key(KC.f(n))) }
        b.kf(KC.digit(0), fn: .key(KC.f(10)))
        b.kf(0x0C, fn: .key(KC.f(11)))
        b.kf(0x0D, fn: .key(KC.f(12)))
        b.kf(KC.backspace, 2, fn: .key(KC.del))
        b.kf(0x29, fn: .key(KC.prtSc), .mod)

        b.row(1)
        b.k(KC.tab, 1.5)
        for c in UInt16(0x10)...0x18 { b.k(c) }
        b.kf(KC.p, fn: .key(KC.prtSc))
        b.kf(0x1A, fn: .key(KC.scrollLock))
        b.kf(0x1B, fn: .key(KC.pause))
        b.k(0x2B, 1.5)
        b.kf(KC.del, fn: .key(KC.ins))

        b.row(2)
        b.k(KC.caps, 1.75)
        for c in UInt16(0x1E)...0x28 { b.k(c) }
        b.k(KC.enter, 2.25)
        b.kf(KC.pgUp, fn: .key(KC.home))

        b.row(3)
        b.k(KC.lshift, 2.25)
        for c in UInt16(0x2C)...0x31 { b.k(c) }
        b.kf(KC.m, fn: .key(KC.volMute))
        for c in UInt16(0x33)...0x35 { b.k(c) }
        b.k(KC.rshift, 1.75)
        b.kf(KC.up, fn: .key(KC.volUp))
        b.kf(KC.pgDn, fn: .key(KC.end))

        b.row(4)
        b.k(KC.lctrl, 1.25)
        b.k(KC.lwin, 1.25)
        b.k(KC.lalt, 1.25)
        b.kf(KC.space, 6.25, fn: .key(KC.playPause))
        b.k(KC.ralt)
        b.a(.special(.fn), 1, nil, .accent)
        b.k(KC.rctrl)
        b.kf(KC.left, fn: .key(KC.prevTrack))
        b.kf(KC.down, fn: .key(KC.volDown))
        b.kf(KC.right, fn: .key(KC.nextTrack))
        return KBLayout(id: "builtin.dp68", name: "Dark Project 68", icon: "keyboard.badge.ellipsis", cols: 16, rows: 5, keys: b.keys, builtIn: true)
    }

    /// 75% keyboard (16u wide) — the main typing area.
    private static func keyboard75(_ b: inout LB, top: Double = 0) {
        b.row(top, h: 0.8)
        b.k(KC.esc)
        for n in 1...12 { b.k(KC.f(n)) }
        b.k(KC.prtSc)
        b.k(KC.del)
        b.a(.special(.langSwitch), 1, nil, .accent)

        b.row(top + 0.8)
        b.k(0x29)
        for n in 1...9 { b.k(KC.digit(n)) }
        b.k(KC.digit(0)); b.k(0x0C); b.k(0x0D)
        b.k(KC.backspace, 2)
        b.k(KC.home)

        b.row(top + 1.8)
        b.k(KC.tab, 1.5)
        b.letters(0x10...0x1B)
        b.k(0x2B, 1.5)
        b.k(KC.pgUp)

        b.row(top + 2.8)
        b.k(KC.caps, 1.75)
        b.letters(0x1E...0x28)
        b.k(KC.enter, 2.25)
        b.k(KC.pgDn)

        b.row(top + 3.8)
        b.k(KC.lshift, 2.25)
        b.letters(0x2C...0x35)
        b.k(KC.rshift, 1.75)
        b.k(KC.up)
        b.k(KC.end)

        b.row(top + 4.8)
        b.k(KC.lctrl, 1.25)
        b.k(KC.lwin, 1.25)
        b.k(KC.lalt, 1.25)
        b.k(KC.space, 6.25)
        b.k(KC.ralt)
        b.k(KC.menu)
        b.k(KC.rctrl)
        b.k(KC.left)
        b.k(KC.down)
        b.k(KC.right)
    }

    static var laptop: KBLayout {
        var b = LB()
        keyboard75(&b)
        b.put(.mouse(0), 0, 5.95, 3.4, 2.65, "ЛКМ")
        b.put(.trackpad, 3.5, 5.95, 9, 2.65)
        b.put(.mouse(1), 12.6, 5.95, 3.4, 2.65, "ПКМ")
        return KBLayout(id: "builtin.laptop", name: "Ноутбук", icon: "laptopcomputer", cols: 16, rows: 8.6, keys: b.keys, builtIn: true)
    }

    static var full: KBLayout {
        var b = LB()
        keyboard75(&b)
        return KBLayout(id: "builtin.full", name: "Клавиатура", icon: "keyboard", cols: 16, rows: 5.8, keys: b.keys, builtIn: true)
    }

    static var gaming: KBLayout {
        var b = LB()
        b.row(0)
        b.k(KC.esc); for n in 1...7 { b.k(KC.digit(n)) }
        b.row(1)
        b.k(KC.tab, 1.5); for c in [KC.q, KC.w, KC.e, KC.r, KC.t, KC.y] { b.k(c) }; b.k(KC.i)
        b.row(2)
        b.k(KC.caps, 1.75); for c in [KC.a, KC.s, KC.d, KC.f, KC.g, KC.h] { b.k(c) }; b.k(KC.m, 0.75)
        b.row(3)
        b.k(KC.lshift, 2.25); for c in [KC.z, KC.x, KC.c, KC.v, KC.b] { b.k(c) }; b.k(KC.enter, 1.25)
        b.row(4)
        b.k(KC.lctrl, 1.5); b.k(KC.lalt, 1.25); b.k(KC.space, 4.25); b.a(.special(.textPanel), 1.5)

        b.put(.mouseLook, 9.0, 0, 7.0, 3.4)
        b.put(.mouse(0), 9.0, 3.5, 2.9, 1.5, "ЛКМ")
        b.put(.wheel(1), 12.0, 3.5, 1.0, 0.75)
        b.put(.wheel(-1), 12.0, 4.25, 1.0, 0.75)
        b.put(.mouse(1), 13.1, 3.5, 2.9, 1.5, "ПКМ")
        return KBLayout(id: "builtin.gaming", name: "Игры", icon: "gamecontroller", cols: 16, rows: 5, keys: b.keys, glide: true, builtIn: true)
    }

    static var gamingStick: KBLayout {
        var b = LB()
        b.row(0)
        b.k(KC.esc); b.k(KC.tab); for n in 1...5 { b.k(KC.digit(n)) }; b.k(KC.m, 1.3)
        b.put(.stick(StickConfig()), 0, 1.15, 4.1, 3.85)
        b.row(1.15, x: 4.3)
        for c in [KC.q, KC.e, KC.r, KC.f] { b.k(c) }
        b.row(2.15, x: 4.3)
        for c in [KC.z, KC.x, KC.c, KC.g] { b.k(c) }
        b.row(3.2, h: 1.8, x: 4.3)
        b.k(KC.lctrl, 1.2)
        b.k(KC.space, 2.8)
        b.put(.mouseLook, 8.6, 0, 7.4, 3.4)
        b.put(.mouse(0), 8.6, 3.5, 3.6, 1.5, "ЛКМ")
        b.put(.mouse(1), 12.4, 3.5, 3.6, 1.5, "ПКМ")
        return KBLayout(id: "builtin.stick", name: "Игры: стик", icon: "l.joystick", cols: 16, rows: 5, keys: b.keys, glide: true, builtIn: true)
    }

    static var trackpad: KBLayout {
        var b = LB()
        b.put(.trackpad, 0, 0, 16, 7.6)
        b.row(7.7, h: 1.3)
        b.a(.mouse(0), 4, "ЛКМ")
        b.k(KC.lctrl, 1.6)
        b.k(KC.lshift, 1.6)
        b.k(KC.lalt, 1.6)
        b.k(KC.lwin, 1.6)
        b.a(.special(.textPanel), 1.6)
        b.a(.mouse(1), 4, "ПКМ")
        return KBLayout(id: "builtin.trackpad", name: "Тачпад", icon: "rectangle.and.hand.point.up.left", cols: 16, rows: 9, keys: b.keys, builtIn: true)
    }

    static var numpad: KBLayout {
        var b = LB()
        b.row(0)
        b.k(KC.prtSc); b.k(KC.scrollLock); b.k(KC.pause)
        b.gap(0.5)
        b.k(KC.numLock); b.k(0xE035); b.k(0x37); b.k(0x4A)
        b.gap(0.5)
        b.k(KC.prevTrack); b.k(KC.playPause); b.k(KC.nextTrack); b.k(KC.stopMedia)

        b.row(1)
        b.k(KC.ins); b.k(KC.home); b.k(KC.pgUp)
        b.gap(0.5)
        b.k(0x47); b.k(0x48); b.k(0x49)
        b.put(.key(0x4E), 6.5, 1, 1, 2)
        b.gap(1.5)
        b.k(KC.volDown); b.k(KC.volMute); b.k(KC.volUp); b.k(0xE021)

        b.row(2)
        b.k(KC.del); b.k(KC.end); b.k(KC.pgDn)
        b.gap(0.5)
        b.k(0x4B); b.k(0x4C); b.k(0x4D)
        b.gap(1.5)
        for n in 13...16 { b.k(KC.f(n)) }

        b.row(3)
        b.gap(1); b.k(KC.up); b.gap(1)
        b.gap(0.5)
        b.k(0x4F); b.k(0x50); b.k(0x51)
        b.put(.key(0xE01C), 6.5, 3, 1, 2)
        b.gap(1.5)
        for n in 17...20 { b.k(KC.f(n)) }

        b.row(4)
        b.k(KC.left); b.k(KC.down); b.k(KC.right)
        b.gap(0.5)
        b.k(0x52, 2); b.k(0x53)
        b.gap(1.5)
        for n in 21...24 { b.k(KC.f(n)) }
        return KBLayout(id: "builtin.numpad", name: "Цифры и медиа", icon: "number.square", cols: 12, rows: 5, keys: b.keys, builtIn: true)
    }

    static var shortcuts: KBLayout {
        let ctrl = KC.lctrl, shift = KC.lshift, alt = KC.lalt, win = KC.lwin
        let items: [(KeyAction, String)] = [
            (.combo([ctrl, KC.c]), "sf:doc.on.doc|Копировать"),
            (.combo([ctrl, KC.v]), "sf:doc.on.clipboard|Вставить"),
            (.combo([ctrl, KC.x]), "sf:scissors|Вырезать"),
            (.combo([ctrl, KC.z]), "sf:arrow.uturn.backward|Отменить"),
            (.combo([ctrl, KC.y]), "sf:arrow.uturn.forward|Повторить"),
            (.combo([ctrl, KC.a]), "sf:selection.pin.in.out|Выделить всё"),

            (.combo([ctrl, KC.s]), "sf:square.and.arrow.down|Сохранить"),
            (.combo([ctrl, KC.f]), "sf:magnifyingglass|Найти"),
            (.combo([ctrl, KC.t]), "sf:plus.square.on.square|Новая вкладка"),
            (.combo([ctrl, KC.w]), "sf:xmark.square|Закрыть вкладку"),
            (.combo([ctrl, shift, KC.t]), "sf:arrow.counterclockwise.square|Вернуть вкладку"),
            (.combo([ctrl, KC.r]), "sf:arrow.clockwise|Обновить"),

            (.combo([alt, KC.tab]), "sf:rectangle.2.swap|Alt+Tab"),
            (.combo([win, KC.d]), "sf:menubar.dock.rectangle|Рабочий стол"),
            (.combo([win, KC.tab]), "sf:square.grid.3x2|Все окна"),
            (.combo([win, KC.e]), "sf:folder|Проводник"),
            (.combo([win, shift, KC.s]), "sf:camera.viewfinder|Скриншот"),
            (.combo([ctrl, shift, KC.esc]), "sf:gauge.with.dots.needle.33percent|Диспетчер задач"),

            (.combo([alt, KC.f(4)]), "sf:xmark.octagon|Закрыть окно"),
            (.combo([win, KC.v]), "sf:list.clipboard|Буфер обмена"),
            (.combo([win, 0x34]), "sf:face.smiling|Эмодзи"),
            (.key(KC.volDown), "sf:speaker.wave.1.fill|Тише"),
            (.key(KC.volUp), "sf:speaker.wave.3.fill|Громче"),
            (.key(KC.playPause), "sf:playpause.fill|Пауза"),
        ]
        var b = LB()
        for (i, item) in items.enumerated() {
            let col = Double(i % 6), row = Double(i / 6)
            let style: KeyStyle = (item.0 == .combo([alt, KC.f(4)])) ? .danger : .normal
            b.put(item.0, col * 2, row * 1.2, 2, 1.2, item.1, style)
        }
        return KBLayout(id: "builtin.shortcuts", name: "Команды", icon: "command", cols: 12, rows: 4.8, keys: b.keys, builtIn: true)
    }
}
