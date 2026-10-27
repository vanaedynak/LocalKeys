package com.localkeys.app

typealias LegendTable = Map<Int, Pair<String, String>>

/** What one printable keycap shows. */
data class KeyLegend(
    /** Big character (what the key types now). */
    val main: String = "",
    /** Top-left: the same key with Shift (symbol keys). */
    val top: String = "",
    /** Bottom-right: the second language. */
    val alt: String = "",
    /** Top-right: the second language with Shift (only where it is a different symbol). */
    val altTop: String = "",
)

/**
 * Built-in legends for the keycaps. When connected, the PC sends the exact legends of its active
 * layout (any language), which take precedence in "auto" mode. Port of Legends.swift.
 */
object Legends {
    private val row1 = listOf(0x29) + (0x02..0x0D)
    private val row2 = (0x10..0x1B).toList() + 0x2B
    private val row3 = (0x1E..0x28).toList()
    private val row4 = (0x2C..0x35).toList()

    private fun make(normal: List<String>, shifted: List<String>, iso: Pair<String, String>): LegendTable {
        val t = HashMap<Int, Pair<String, String>>()
        listOf(row1, row2, row3, row4).forEachIndexed { ri, codes ->
            val n = normal[ri].codePoints().toArray()
            val s = shifted[ri].codePoints().toArray()
            codes.forEachIndexed { i, c ->
                if (i < n.size && i < s.size) t[c] = String(Character.toChars(n[i])) to String(Character.toChars(s[i]))
            }
        }
        t[0x56] = iso
        return t
    }

    val en = make(
        listOf("`1234567890-=", "qwertyuiop[]\\", "asdfghjkl;'", "zxcvbnm,./"),
        listOf("~!@#$%^&*()_+", "QWERTYUIOP{}|", "ASDFGHJKL:\"", "ZXCVBNM<>?"), "\\" to "|")
    val ru = make(
        listOf("ё1234567890-=", "йцукенгшщзхъ\\", "фывапролджэ", "ячсмитьбю."),
        listOf("Ё!\"№;%:?*()_+", "ЙЦУКЕНГШЩЗХЪ/", "ФЫВАПРОЛДЖЭ", "ЯЧСМИТЬБЮ,"), "\\" to "/")
    val ua = make(
        listOf("'1234567890-=", "йцукенгшщзхїґ", "фівапролджє", "ячсмитьбю."),
        listOf("₴!\"№;%:?*()_+", "ЙЦУКЕНГШЩЗХЇҐ", "ФІВАПРОЛДЖЄ", "ЯЧСМИТЬБЮ,"), "\\" to "/")

    private fun isLetter(s: String) = s.isNotEmpty() && Character.isLetter(s.codePointAt(0))

    /**
     * Keycap legend of a printable key: the active language plus, when enabled, the second one
     * (letters, and punctuation that moves between layouts, e.g. EN "/" is "." in Russian).
     */
    fun format(code: Int, r: Resolved, shift: Boolean, altShifted: Boolean): KeyLegend? {
        val (n, s) = r.primary[code] ?: return null
        var main: String
        var top = ""
        if (isLetter(n)) {
            main = n.uppercase()
        } else {
            main = if (shift) s else n
            val t = if (shift) n else s
            top = if (t == main) "" else t
        }
        val sec = r.secondary?.get(code) ?: return KeyLegend(main, top)
        val (sn, ss) = sec
        var alt = ""
        if (isLetter(sn)) {
            val a = sn.uppercase()
            if (a != main) alt = a
        } else if (sn.isNotEmpty() && sn != n && sn != s) {
            alt = sn
        }
        var altTop = ""
        // The second language's Shift symbol, where it differs (2 → " and 3 → № in Russian, / → ,).
        if (altShifted && !isLetter(sn) && ss.isNotEmpty() && ss != sn && ss != n && ss != s && ss != alt) altTop = ss
        return KeyLegend(main, top, alt, altTop)
    }

    fun table(lang: String): LegendTable = when (lang.uppercase()) {
        "RU" -> ru
        "UA", "UK" -> ua
        else -> en
    }

    class Resolved(val primary: LegendTable, val primaryLang: String, val secondary: LegendTable?)

    fun resolve(pc: PcState?): Resolved {
        var primary = en
        var lang = "EN"
        if (Settings.legendMode == "auto") {
            if (pc != null && pc.legends.isNotEmpty()) {
                primary = pc.legends
                lang = (pc.lang ?: "EN").uppercase()
            }
        } else {
            lang = Settings.legendMode.uppercase()
            primary = table(lang)
        }
        val secondary = if (!Settings.bilingual) null
        else if (lang == "EN") (if (Settings.secondLang == "none") null else table(Settings.secondLang))
        else en
        return Resolved(primary, lang, secondary)
    }
}
