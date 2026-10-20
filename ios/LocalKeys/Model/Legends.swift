import Foundation

typealias LegendTable = [UInt16: (String, String)]

/// Built-in legends for the keycaps. When connected, the PC sends the exact legends of its
/// active layout (any language), which take precedence in "auto" mode.
enum Legends {
    private static let row1: [UInt16] = [0x29] + (0x02...0x0D).map { UInt16($0) }
    private static let row2: [UInt16] = (0x10...0x1B).map { UInt16($0) } + [0x2B]
    private static let row3: [UInt16] = (0x1E...0x28).map { UInt16($0) }
    private static let row4: [UInt16] = (0x2C...0x35).map { UInt16($0) }

    private static func make(_ normal: [String], _ shifted: [String]) -> LegendTable {
        var t: LegendTable = [:]
        let rows = [row1, row2, row3, row4]
        for (ri, codes) in rows.enumerated() {
            let n = Array(normal[ri]), s = Array(shifted[ri])
            for (i, c) in codes.enumerated() where i < n.count && i < s.count {
                t[c] = (String(n[i]), String(s[i]))
            }
        }
        return t
    }

    static let en: LegendTable = {
        var t = make(["`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"],
                     ["~!@#$%^&*()_+", "QWERTYUIOP{}|", "ASDFGHJKL:\"", "ZXCVBNM<>?"])
        t[0x56] = ("\\", "|")
        return t
    }()

    static let ru: LegendTable = {
        var t = make(["ё1234567890-=", "йцукенгшщзхъ\\", "фывапролджэ", "ячсмитьбю."],
                     ["Ё!\"№;%:?*()_+", "ЙЦУКЕНГШЩЗХЪ/", "ФЫВАПРОЛДЖЭ", "ЯЧСМИТЬБЮ,"])
        t[0x56] = ("\\", "/")
        return t
    }()

    static let ua: LegendTable = {
        var t = make(["'1234567890-=", "йцукенгшщзхїґ", "фівапролджє", "ячсмитьбю."],
                     ["₴!\"№;%:?*()_+", "ЙЦУКЕНГШЩЗХЇҐ", "ФІВАПРОЛДЖЄ", "ЯЧСМИТЬБЮ,"])
        t[0x56] = ("\\", "/")
        return t
    }()

    static func table(for lang: String) -> LegendTable {
        switch lang.uppercased() {
        case "RU": return ru
        case "UA", "UK": return ua
        default: return en
        }
    }

    static func fromPC(_ state: PcState?) -> LegendTable? {
        guard let legends = state?.legends, !legends.isEmpty else { return nil }
        var t: LegendTable = [:]
        for (k, v) in legends {
            guard let code = UInt16(k), v.count >= 2 else { continue }
            t[code] = (v[0], v[1])
        }
        return t.isEmpty ? nil : t
    }

    struct Resolved {
        var primary: LegendTable
        var primaryLang: String
        var secondary: LegendTable?
    }

    static func resolve(settings: AppSettings, pc: PcState?) -> Resolved {
        var primary = en
        var lang = "EN"
        switch settings.legendMode {
        case "auto":
            if let t = fromPC(pc) {
                primary = t
                lang = (pc?.lang ?? "EN").uppercased()
            }
        default:
            lang = settings.legendMode.uppercased()
            primary = table(for: lang)
        }
        var secondary: LegendTable?
        if settings.bilingual {
            if lang == "EN" {
                secondary = settings.secondLang == "none" ? nil : table(for: settings.secondLang)
            } else {
                secondary = en
            }
        }
        return Resolved(primary: primary, primaryLang: lang, secondary: secondary)
    }
}
