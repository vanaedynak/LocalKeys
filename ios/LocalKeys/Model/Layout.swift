import Foundation

enum SpecialAction: String, Codable, CaseIterable, Identifiable {
    case langSwitch
    case textPanel
    case nextLayout
    case releaseAll
    case fn

    var id: String { rawValue }
    var title: String {
        switch self {
        case .langSwitch: return "Сменить язык ввода"
        case .textPanel: return "Панель ввода текста"
        case .nextLayout: return "Следующая раскладка"
        case .releaseAll: return "Отпустить всё"
        case .fn: return "Fn (второй слой)"
        }
    }
    var cap: String {
        switch self {
        case .langSwitch: return "sf:globe"
        case .textPanel: return "sf:character.cursor.ibeam"
        case .nextLayout: return "sf:rectangle.2.swap"
        case .releaseAll: return "sf:hand.raised.slash"
        case .fn: return "Fn"
        }
    }
}

struct StickConfig: Codable, Hashable {
    var up: UInt16 = KC.w
    var left: UInt16 = KC.a
    var down: UInt16 = KC.s
    var right: UInt16 = KC.d
    /// Held when the stick is pushed far forward (e.g. Shift to sprint). nil = off.
    var sprint: UInt16? = KC.lshift
    /// Dead zone as a fraction of the stick radius (default 0.28).
    var deadzone: Double? = nil
    /// Push distance (in radii) at which sprint engages (default 1.3).
    var sprintAt: Double? = nil
    /// true: the stick centre is the middle of the element; false/nil: it floats to where the finger lands.
    var fixedCenter: Bool? = nil
    /// Sprint stays on after it engaged until the finger is lifted.
    var sprintLatch: Bool? = nil
}

/// What turning a scroll wheel strip does. One detent = one step.
enum WheelMode: String, Codable, CaseIterable, Identifiable {
    case scroll, hscroll, volume, zoom, tabs, windows, undo, arrows

    var id: String { rawValue }
    var title: String {
        switch self {
        case .scroll: return "Прокрутка"
        case .hscroll: return "Прокрутка вбок"
        case .volume: return "Громкость"
        case .zoom: return "Масштаб (Ctrl + колесо)"
        case .tabs: return "Вкладки (Ctrl+Tab)"
        case .windows: return "Окна (Alt+Tab)"
        case .undo: return "Отменить / повторить"
        case .arrows: return "Стрелки"
        }
    }
    var symbol: String {
        switch self {
        case .scroll: return "arrow.up.arrow.down"
        case .hscroll: return "arrow.left.arrow.right"
        case .volume: return "speaker.wave.2.fill"
        case .zoom: return "plus.magnifyingglass"
        case .tabs: return "square.on.square"
        case .windows: return "macwindow.on.rectangle"
        case .undo: return "arrow.uturn.backward"
        case .arrows: return "arrow.up.and.down.square"
        }
    }
    var isScroll: Bool { self == .scroll || self == .hscroll }
}

struct WheelConfig: Codable, Hashable {
    var mode: WheelMode = .scroll
    /// Distance between detents in points. nil = 26.
    var notch: Double? = nil
    /// Scroll modes: pixel-smooth scrolling instead of whole notches.
    var smooth: Bool? = nil
    /// Scroll modes: keep spinning after a flick, like a free-spinning wheel. nil = on.
    var spin: Bool? = nil
    /// Reverse the direction.
    var invert: Bool? = nil
}

enum KeyAction: Codable, Hashable {
    case key(UInt16)
    case combo([UInt16])
    case mouse(UInt8)
    case wheel(Int16)
    case text(String)
    case special(SpecialAction)
    case switchLayout(String)
    case trackpad
    case mouseLook
    case stick(StickConfig)
    case scrollWheel(WheelConfig)

    var isZone: Bool {
        switch self {
        case .trackpad, .mouseLook, .stick, .scrollWheel: return true
        default: return false
        }
    }
}

enum KeyStyle: String, Codable, CaseIterable, Identifiable {
    case auto, normal, mod, accent, danger
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Авто"
        case .normal: return "Обычная"
        case .mod: return "Служебная"
        case .accent: return "Акцент"
        case .danger: return "Красная"
        }
    }
}

struct KeyDef: Codable, Hashable, Identifiable {
    var id = UUID()
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var action: KeyAction
    var label: String? = nil
    /// Tap to latch, tap again to release (e.g. auto-run in games).
    var toggle: Bool = false
    var style: KeyStyle = .auto
    /// Action while an Fn key is held (second layer, like on compact keyboards). nil = same as normal.
    var fn: KeyAction? = nil
}

struct KBLayout: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var icon: String
    var cols: Double
    var rows: Double
    var keys: [KeyDef]
    /// Sliding a finger from one key to another releases the first and presses the second.
    var glide: Bool = false
    var builtIn: Bool = false
}

extension KeyDef {
    func resolvedStyle() -> KeyStyle {
        if style != .auto { return style }
        switch action {
        case .key(let c):
            if KeyCatalog.isModifier(c) { return .mod }
            if KeyCatalog.printable.contains(c) || c == KC.space { return .normal }
            if [KC.enter].contains(c) { return .accent }
            return .mod
        case .mouse, .wheel: return .mod
        case .special, .switchLayout: return .mod
        case .combo, .text: return .normal
        default: return .normal
        }
    }

    /// Text shown when the key has no custom label and no layout legend.
    func defaultCap() -> String {
        switch action {
        case .key(let c): return KeyCatalog.cap(c)
        case .combo(let cs): return cs.map { KeyCatalog.cap($0).hasPrefix("sf:") ? KeyCatalog.name($0) : KeyCatalog.cap($0) }.joined(separator: "+")
        case .mouse(let b): return ["ЛКМ", "ПКМ", "СКМ", "X1", "X2"][Int(min(b, 4))]
        case .wheel(let d): return d > 0 ? "sf:chevron.up.circle" : "sf:chevron.down.circle"
        case .text(let s): return s
        case .special(let s): return s.cap
        case .switchLayout: return "sf:rectangle.2.swap"
        case .trackpad: return "Тачпад"
        case .mouseLook: return "Обзор"
        case .stick: return "Стик"
        case .scrollWheel(let c): return c.mode.title
        }
    }
}
