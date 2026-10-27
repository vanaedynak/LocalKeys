package com.localkeys.app

/** Scan codes (PC set 1). High byte 0xE0 marks an extended key. Must match the Windows agent. */
object Keys {
    const val ESC = 0x01
    const val BACKSPACE = 0x0E
    const val TAB = 0x0F
    const val ENTER = 0x1C
    const val LCTRL = 0x1D
    const val LSHIFT = 0x2A
    const val RSHIFT = 0x36
    const val LALT = 0x38
    const val SPACE = 0x39
    const val CAPS = 0x3A
    const val NUM_LOCK = 0x45
    const val SCROLL_LOCK = 0x46
    const val RCTRL = 0xE01D
    const val RALT = 0xE038
    const val LWIN = 0xE05B
    const val RWIN = 0xE05C
    const val MENU = 0xE05D
    const val HOME = 0xE047
    const val UP = 0xE048
    const val PG_UP = 0xE049
    const val LEFT = 0xE04B
    const val RIGHT = 0xE04D
    const val END = 0xE04F
    const val DOWN = 0xE050
    const val PG_DN = 0xE051
    const val INS = 0xE052
    const val DEL = 0xE053
    const val PRT_SC = 0xE037
    const val PAUSE = 0xE145
    const val VOL_MUTE = 0xE020
    const val VOL_DOWN = 0xE02E
    const val VOL_UP = 0xE030
    const val PLAY_PAUSE = 0xE022
    const val NEXT_TRACK = 0xE019
    const val PREV_TRACK = 0xE010
    const val P = 0x19
    const val M = 0x32

    fun digit(n: Int) = if (n == 0) 0x0B else 0x01 + n
    fun f(n: Int) = when (n) {
        in 1..10 -> 0x3A + n
        11 -> 0x57
        12 -> 0x58
        else -> 0
    }

    private val modifiers = setOf(LSHIFT, RSHIFT, LCTRL, RCTRL, LALT, RALT, LWIN, RWIN)
    fun isModifier(c: Int) = c in modifiers

    /** Keys whose cap shows characters from the active keyboard layout. */
    val printable: Set<Int> = HashSet<Int>().apply {
        addAll(listOf(0x29, 0x2B, 0x56))
        addAll(0x02..0x0D); addAll(0x10..0x1B); addAll(0x1E..0x28); addAll(0x2C..0x35)
    }

    /** Keycap legend. "ic:name" is a vector icon drawn by the keyboard. */
    fun cap(c: Int): String = caps[c] ?: String.format("%04X", c)

    /** Short text-only legend (small Fn hints on keycaps). */
    fun short(c: Int): String = shorts[c] ?: cap(c).let { if (it.startsWith("ic:")) "" else it }

    private val caps: Map<Int, String> = HashMap<Int, String>().apply {
        "QWERTYUIOP".forEachIndexed { i, ch -> put(0x10 + i, ch.toString()) }
        "ASDFGHJKL".forEachIndexed { i, ch -> put(0x1E + i, ch.toString()) }
        "ZXCVBNM".forEachIndexed { i, ch -> put(0x2C + i, ch.toString()) }
        put(0x29, "`"); for (n in 0..9) put(digit(n), n.toString())
        put(0x0C, "-"); put(0x0D, "="); put(0x1A, "["); put(0x1B, "]"); put(0x2B, "\\")
        put(0x27, ";"); put(0x28, "'"); put(0x33, ","); put(0x34, "."); put(0x35, "/"); put(0x56, "\\")
        put(LSHIFT, "Shift"); put(RSHIFT, "Shift"); put(LCTRL, "Ctrl"); put(RCTRL, "Ctrl")
        put(LALT, "Alt"); put(RALT, "Alt"); put(LWIN, "ic:win"); put(RWIN, "ic:win"); put(MENU, "ic:menu")
        put(ESC, "Esc"); put(TAB, "Tab"); put(CAPS, "Caps"); put(ENTER, "Enter"); put(BACKSPACE, "ic:backspace")
        put(SPACE, ""); put(INS, "Ins"); put(DEL, "Del"); put(PRT_SC, "PrtSc"); put(SCROLL_LOCK, "ScrLk"); put(PAUSE, "Pause")
        put(NUM_LOCK, "Num")
        put(HOME, "Home"); put(END, "End"); put(PG_UP, "PgUp"); put(PG_DN, "PgDn")
        put(UP, "ic:up"); put(DOWN, "ic:down"); put(LEFT, "ic:left"); put(RIGHT, "ic:right")
        for (n in 1..12) put(f(n), "F$n")
        put(VOL_MUTE, "Mute"); put(VOL_DOWN, "Vol−"); put(VOL_UP, "Vol+")
        put(PLAY_PAUSE, "Play"); put(NEXT_TRACK, "Next"); put(PREV_TRACK, "Prev")
    }

    private val shorts: Map<Int, String> = mapOf(
        UP to "↑", DOWN to "↓", LEFT to "←", RIGHT to "→", LWIN to "Win", RWIN to "Win",
        BACKSPACE to "⌫", MENU to "Menu", VOL_MUTE to "Mute", VOL_DOWN to "Vol−", VOL_UP to "Vol+",
        PLAY_PAUSE to "Play", NEXT_TRACK to "Next", PREV_TRACK to "Prev",
    )
}
