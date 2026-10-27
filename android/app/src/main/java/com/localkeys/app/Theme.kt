package com.localkeys.app

import android.graphics.Color

/** Keyboard color themes: the same four as on the iPad. */
class KTheme(
    val id: String,
    val name: String,
    val bg: Int,
    val bar: Int,
    val key: Int,
    val keyMod: Int,
    val keyAccent: Int,
    val keyDanger: Int,
    val pressed: Int,
    val latched: Int,
    val text: Int,
    val textDim: Int,
    val border: Int,
    val accent: Int,
    val shadow: Boolean,
) {
    val isLight get() = id == "light"

    companion object {
        private fun c(r: Double, g: Double, b: Double, a: Double = 1.0) =
            Color.argb((a * 255).toInt(), (r * 255).toInt(), (g * 255).toInt(), (b * 255).toInt())
        private fun w(v: Double, a: Double = 1.0) = c(v, v, v, a)

        val midnight = KTheme(
            "midnight", "Полночь",
            bg = c(0.055, 0.063, 0.086), bar = c(0.075, 0.083, 0.11),
            key = c(0.145, 0.157, 0.2), keyMod = c(0.105, 0.115, 0.15),
            keyAccent = c(0.30, 0.40, 0.98), keyDanger = c(0.62, 0.18, 0.22),
            pressed = c(0.42, 0.55, 1.0), latched = c(0.95, 0.68, 0.25),
            text = w(0.95), textDim = w(0.62), border = w(1.0, 0.06),
            accent = c(0.45, 0.58, 1.0), shadow = true)

        val graphite = KTheme(
            "graphite", "Графит",
            bg = w(0.10), bar = w(0.12), key = w(0.21), keyMod = w(0.155),
            keyAccent = c(0.16, 0.62, 0.48), keyDanger = c(0.62, 0.2, 0.2),
            pressed = c(0.25, 0.8, 0.62), latched = c(0.95, 0.7, 0.3),
            text = w(0.93), textDim = w(0.6), border = w(1.0, 0.05),
            accent = c(0.3, 0.85, 0.65), shadow = true)

        val light = KTheme(
            "light", "Светлая",
            bg = c(0.84, 0.85, 0.88), bar = c(0.88, 0.89, 0.92), key = Color.WHITE, keyMod = c(0.74, 0.76, 0.8),
            keyAccent = c(0.2, 0.45, 0.95), keyDanger = c(0.9, 0.35, 0.35),
            pressed = c(0.55, 0.7, 1.0), latched = c(1.0, 0.75, 0.3),
            text = w(0.08), textDim = w(0.4), border = w(0.0, 0.08),
            accent = c(0.2, 0.45, 0.95), shadow = true)

        val neon = KTheme(
            "neon", "Неон",
            bg = c(0.03, 0.02, 0.06), bar = c(0.05, 0.03, 0.09), key = c(0.09, 0.06, 0.15), keyMod = c(0.06, 0.04, 0.11),
            keyAccent = c(0.85, 0.15, 0.75), keyDanger = c(0.8, 0.1, 0.25),
            pressed = c(0.0, 0.95, 0.95), latched = c(1.0, 0.85, 0.1),
            text = c(0.85, 0.95, 1.0), textDim = c(0.6, 0.5, 0.85), border = c(0.6, 0.3, 1.0, 0.35),
            accent = c(0.0, 0.95, 0.95), shadow = false)

        val all = listOf(midnight, graphite, light, neon)
        fun byId(id: String) = all.firstOrNull { it.id == id } ?: midnight

        fun blend(a: Int, b: Int, t: Float): Int {
            fun ch(x: Int, y: Int) = (x + (y - x) * t).toInt()
            return Color.argb(ch(Color.alpha(a), Color.alpha(b)), ch(Color.red(a), Color.red(b)),
                ch(Color.green(a), Color.green(b)), ch(Color.blue(a), Color.blue(b)))
        }

        fun alpha(c: Int, a: Float) = Color.argb((Color.alpha(c) * a).toInt(), Color.red(c), Color.green(c), Color.blue(c))
    }
}
