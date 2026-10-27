package com.localkeys.app

enum class Special { FN, LANG_SWITCH, TEXT_PANEL, RELEASE_ALL }

sealed class KeyAction {
    data class Key(val code: Int) : KeyAction()
    data class Sp(val special: Special) : KeyAction()
}

enum class KeyStyle { AUTO, NORMAL, MOD, ACCENT, DANGER }

class KeyDef(
    val x: Float, val y: Float, val w: Float, val h: Float,
    val action: KeyAction,
    val style: KeyStyle = KeyStyle.AUTO,
    /** Action while Fn is held (second layer, like on the real keyboard). */
    val fn: KeyAction? = null,
) {
    fun resolvedStyle(): KeyStyle {
        if (style != KeyStyle.AUTO) return style
        return when (val a = action) {
            is KeyAction.Key -> when {
                Keys.isModifier(a.code) -> KeyStyle.MOD
                a.code in Keys.printable || a.code == Keys.SPACE -> KeyStyle.NORMAL
                a.code == Keys.ENTER -> KeyStyle.ACCENT
                else -> KeyStyle.MOD
            }
            is KeyAction.Sp -> KeyStyle.MOD
        }
    }
}

class KBLayout(val name: String, val cols: Float, val rows: Float, val keys: List<KeyDef>)

/**
 * 65% / 68 keys, modelled after Dark Project 68 (ANSI): no F-row and no nav cluster,
 * right column ` / Del / PgUp / PgDn, arrows; F1–F12 and media on the Fn layer.
 * Same as BuiltinLayouts.darkProject68 on the iPad.
 */
object Dp68 {
    private class LB {
        val keys = ArrayList<KeyDef>()
        var x = 0f
        var y = 0f

        fun row(y: Float) { this.y = y; x = 0f }
        fun k(code: Int, w: Float = 1f, style: KeyStyle = KeyStyle.AUTO, fn: KeyAction? = null) {
            keys.add(KeyDef(x, y, w, 1f, KeyAction.Key(code), style, fn))
            x += w
        }
        fun kf(code: Int, w: Float = 1f, fn: Int, style: KeyStyle = KeyStyle.AUTO) = k(code, w, style, KeyAction.Key(fn))
        fun sp(s: Special, w: Float = 1f, style: KeyStyle = KeyStyle.AUTO) {
            keys.add(KeyDef(x, y, w, 1f, KeyAction.Sp(s), style))
            x += w
        }
    }

    val layout: KBLayout by lazy {
        val b = LB()
        b.row(0f)
        b.k(Keys.ESC)
        for (n in 1..9) b.kf(Keys.digit(n), fn = Keys.f(n))
        b.kf(Keys.digit(0), fn = Keys.f(10))
        b.kf(0x0C, fn = Keys.f(11))
        b.kf(0x0D, fn = Keys.f(12))
        b.kf(Keys.BACKSPACE, 2f, fn = Keys.DEL)
        b.kf(0x29, fn = Keys.PRT_SC, style = KeyStyle.MOD)

        b.row(1f)
        b.k(Keys.TAB, 1.5f)
        for (c in 0x10..0x18) b.k(c)
        b.kf(Keys.P, fn = Keys.PRT_SC)
        b.kf(0x1A, fn = Keys.SCROLL_LOCK)
        b.kf(0x1B, fn = Keys.PAUSE)
        b.k(0x2B, 1.5f)
        b.kf(Keys.DEL, fn = Keys.INS)

        b.row(2f)
        b.k(Keys.CAPS, 1.75f)
        for (c in 0x1E..0x28) b.k(c)
        b.k(Keys.ENTER, 2.25f)
        b.kf(Keys.PG_UP, fn = Keys.HOME)

        b.row(3f)
        b.k(Keys.LSHIFT, 2.25f)
        for (c in 0x2C..0x31) b.k(c)
        b.kf(Keys.M, fn = Keys.VOL_MUTE)
        for (c in 0x33..0x35) b.k(c)
        b.k(Keys.RSHIFT, 1.75f)
        b.kf(Keys.UP, fn = Keys.VOL_UP)
        b.kf(Keys.PG_DN, fn = Keys.END)

        b.row(4f)
        b.k(Keys.LCTRL, 1.25f)
        b.k(Keys.LWIN, 1.25f)
        b.k(Keys.LALT, 1.25f)
        b.kf(Keys.SPACE, 6.25f, fn = Keys.PLAY_PAUSE)
        b.k(Keys.RALT)
        b.sp(Special.FN, 1f, KeyStyle.ACCENT)
        b.k(Keys.RCTRL)
        b.kf(Keys.LEFT, fn = Keys.PREV_TRACK)
        b.kf(Keys.DOWN, fn = Keys.VOL_DOWN)
        b.kf(Keys.RIGHT, fn = Keys.NEXT_TRACK)
        KBLayout("Dark Project 68", 16f, 5f, b.keys)
    }
}
