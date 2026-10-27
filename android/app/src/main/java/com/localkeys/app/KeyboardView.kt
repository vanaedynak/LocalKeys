package com.localkeys.app

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.media.AudioManager
import android.os.Build
import android.util.SparseArray
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * The keyboard: drawn on one canvas (cheap to redraw, no view per key) and tracking every pointer
 * individually, so any number of keys can be held at once, each with its own press and release.
 * Keycaps follow KeyCapView on the iPad: shifted symbol top-left, second language bottom-right
 * (large two-language letters), second language's Shift symbol top-right, Fn hint bottom-left.
 */
@SuppressLint("ViewConstructor")
class KeyboardView(ctx: Context) : View(ctx) {
    private val layout = Dp68.layout
    private val dp = resources.displayMetrics.density
    var theme = KTheme.byId(Settings.themeId)
        set(v) { field = v; invalidate() }

    /** Fn held alone for a moment: open the menu (works with the top bar hidden). */
    var onMenu: (() -> Unit)? = null
    var onSpecial: ((Special) -> Unit)? = null

    private class Label {
        var text = ""
        var size = 0f
        var x = 0f
        var y = 0f
        var align = Paint.Align.CENTER
    }

    private inner class Cap(val def: KeyDef) {
        val cell = RectF()
        val rect = RectF()
        val style = def.resolvedStyle()
        var pressCount = 0
        var pressed = false
        var latched = false
        var fnLayer = false
        var led: Boolean? = null
        var legend = KeyLegend()
        var fnHint = ""
        var icon: String? = null
        val main = Label()
        val top = Label()
        val alt = Label()
        val altTop = Label()
        val fn = Label()
        val iconBox = RectF()
        val ledBox = RectF()
        var radius = 0f
    }

    private val caps = layout.keys.map { Cap(it) }
    private var fnHeld = 0
    private var fnSolo = false
    private var lastShift = false
    private var legends = Legends.resolve(null)
    private var altScale = Settings.altScale

    /** pointer id -> (cap index, pressed on the Fn layer); index -1 = ignored. */
    private val bindings = SparseArray<Pair<Int, Boolean>>()

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG)
    private val fMedium = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    private val fRegular = Typeface.DEFAULT
    private val fSemibold = if (Build.VERSION.SDK_INT >= 28) Typeface.create(Typeface.DEFAULT, 600, false) else fMedium
    private val path = Path()
    private val tmp = RectF()
    private val audio = ctx.getSystemService(AudioManager::class.java)

    private val input = InputController

    init {
        isHapticFeedbackEnabled = true
        updateLegends()
    }

    // MARK: geometry

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        relayout()
    }

    fun relayout() {
        if (width == 0 || height == 0) return
        val pad = 3 * dp
        val availW = max(width - paddingLeft - paddingRight - pad * 2, 1f)
        val availH = max(height - paddingTop - paddingBottom - pad * 2, 1f)
        var ux = availW / layout.cols
        var uy = availH / layout.rows
        val aspect = Settings.keyAspect
        if (uy > ux * aspect) uy = ux * aspect
        if (ux > uy * 1.6f) ux = uy * 1.6f
        val scale = Settings.kbScale
        ux *= scale
        uy *= scale
        val ox = paddingLeft + pad + (availW - ux * layout.cols) / 2
        val oy = paddingTop + pad + max(0f, availH - uy * layout.rows) * Settings.vpos.coerceIn(0f, 1f)
        val gap = Settings.keyGap * dp
        altScale = Settings.altScale
        for (c in caps) {
            val k = c.def
            c.cell.set(ox + k.x * ux, oy + k.y * uy, ox + (k.x + k.w) * ux, oy + (k.y + k.h) * uy)
            c.rect.set(c.cell)
            c.rect.inset(gap / 2, gap / 2)
            prepare(c)
        }
        if (Build.VERSION.SDK_INT >= 29) {
            // Side swipes are the system Back gesture: keep it off the keys at the screen edges
            // (the system allows up to 200dp per edge; the lower rows hold Ctrl/Shift/arrows).
            val h = (200 * dp).toInt()
            val w = (40 * dp).toInt()
            systemGestureExclusionRects = listOf(Rect(0, height - h, w, height), Rect(width - w, height - h, width, height))
        }
        invalidate()
    }

    private fun element(x: Float, y: Float): Int {
        for (i in caps.indices.reversed()) if (caps[i].cell.contains(x, y)) return i
        // In a gap / just outside: snap to the nearest key within a small slack.
        var best = -1
        var bestD = 14 * dp
        for (i in caps.indices) {
            val c = caps[i].cell
            val dx = max(max(c.left - x, 0f), x - c.right)
            val dy = max(max(c.top - y, 0f), y - c.bottom)
            val d = hypot(dx, dy)
            if (d < bestD) { bestD = d; best = i }
        }
        return best
    }

    // MARK: legends & visual state

    private fun actionOf(k: KeyDef, fn: Boolean) = if (fn && k.fn != null) k.fn else k.action

    private fun legendFor(a: KeyAction): KeyLegend = when (a) {
        is KeyAction.Sp -> when (a.special) {
            Special.FN -> KeyLegend("Fn")
            Special.LANG_SWITCH -> KeyLegend("Яз")
            Special.TEXT_PANEL -> KeyLegend("Аа")
            Special.RELEASE_ALL -> KeyLegend("Отп")
        }
        is KeyAction.Key -> {
            val c = a.code
            when {
                c == Keys.SPACE -> KeyLegend(ConnectionManager.pcState?.layoutName ?: "")
                c in Keys.printable -> Legends.format(c, legends, input.shiftActive, Settings.altShifted) ?: KeyLegend(Keys.cap(c))
                else -> KeyLegend(Keys.cap(c))
            }
        }
    }

    private fun fnHint(k: KeyDef): String = when (val f = k.fn) {
        is KeyAction.Key -> Keys.short(f.code)
        else -> ""
    }

    /** `resolve`: rebuild the legend tables (PC layout or settings changed). Shift / Fn only relabel. */
    fun updateLegends(resolve: Boolean = true) {
        if (resolve) legends = Legends.resolve(ConnectionManager.pcState)
        altScale = Settings.altScale
        val pc = ConnectionManager.pcState
        for (c in caps) {
            val fnOn = fnHeld > 0 && c.def.fn != null
            val l = legendFor(actionOf(c.def, fnOn))
            c.legend = l
            c.fnHint = if (fnHeld > 0) "" else fnHint(c.def)
            c.fnLayer = fnOn
            val a = c.def.action
            c.led = if (a is KeyAction.Key) when (a.code) {
                Keys.CAPS -> pc?.caps ?: false
                Keys.NUM_LOCK -> pc?.num ?: false
                Keys.SCROLL_LOCK -> pc?.scroll ?: false
                else -> null
            } else null
            prepare(c)
        }
        invalidate()
    }

    private fun refreshStates() {
        var changed = false
        for (c in caps) {
            var pressed = c.pressCount > 0
            var latched = false
            val a = c.def.action
            if (a is KeyAction.Key) {
                if (input.latched[a.code] != null) latched = true
                else if (input.isHeld(a.code)) pressed = true    // held through another key (the other Shift...)
            }
            if (pressed != c.pressed || latched != c.latched) {
                c.pressed = pressed
                c.latched = latched
                changed = true
            }
        }
        if (changed) invalidate()
    }

    fun onInputState() {
        // Only Shift changes what the keycaps say (symbol row); other modifiers just recolor.
        val shift = input.shiftActive
        if (shift != lastShift) {
            lastShift = shift
            updateLegends(resolve = false)
        }
        refreshStates()
    }

    // MARK: keycap layout (sizes in dp, like the iPad's points)

    private fun fit(l: Label, text: String, box: RectF, size: Float, face: Typeface, align: Paint.Align) {
        l.text = text
        l.align = align
        if (text.isEmpty() || box.width() <= 0) { l.size = 0f; return }
        textPaint.typeface = face
        textPaint.textSize = size
        val w = textPaint.measureText(text)
        var s = size
        if (w > box.width()) s = max(size * box.width() / w, size * 0.45f)
        textPaint.textSize = s
        l.size = s
        l.x = when (align) {
            Paint.Align.LEFT -> box.left
            Paint.Align.RIGHT -> box.right
            else -> box.centerX()
        }
        val fm = textPaint.fontMetrics
        l.y = box.centerY() - (fm.ascent + fm.descent) / 2
    }

    private fun prepare(c: Cap) {
        val r = c.rect
        if (r.width() <= 0) return
        val w = r.width()
        val h = r.height()
        val unit = min(w, h)
        val lg = c.legend
        var mainText = lg.main
        c.icon = null
        if (mainText.startsWith("ic:")) {
            c.icon = mainText.substring(3)
            mainText = ""
        }
        val hasSub = lg.top.isNotEmpty() || lg.alt.isNotEmpty() || lg.altTop.isNotEmpty()
        val small = (unit * 0.22f).coerceIn(8 * dp, 15 * dp)
        val longMain = mainText.codePointCount(0, mainText.length) > 2
        val baseMain = min(unit * (if (longMain) 0.27f else 0.4f), 30 * dp)
        val altSize = (baseMain * altScale).coerceIn(8 * dp, 28 * dp)
        val altTopSize = (altSize * 0.8f).coerceIn(8 * dp, 20 * dp)
        // A large second language turns a letter key into a two-language keycap.
        val bigAlt = lg.alt.isNotEmpty() && altScale > 0.62f && !longMain
        var mainSize = if (bigAlt) baseMain * (1 - (altScale - 0.62f) * 0.35f) else baseMain
        if (longMain) mainSize = max(mainSize, 11 * dp)
        val inset = max(unit * 0.1f, 4 * dp)
        val x0 = r.left
        val y0 = r.top

        if (c.icon != null) {
            val side = min(unit * 0.42f, 30 * dp)
            c.iconBox.set(r.centerX() - side / 2, r.centerY() - side / 2, r.centerX() + side / 2, r.centerY() + side / 2)
            c.main.text = ""
        } else {
            when {
                bigAlt && lg.top.isEmpty() ->
                    tmp.set(x0 + inset * 0.6f, y0 + inset * 0.3f, x0 + inset * 0.6f + w * 0.62f, y0 + h - altSize * 0.95f - inset * 0.3f)
                bigAlt -> tmp.set(x0 + inset, y0 + h * 0.18f, x0 + w * 0.68f, y0 + h * 0.78f)
                hasSub && !longMain -> tmp.set(x0 + inset, y0 + h * 0.2f, x0 + w - inset, y0 + h * 0.82f)
                else -> tmp.set(x0 + inset, y0 + inset * 0.5f, x0 + w - inset, y0 + h - inset * 0.5f)
            }
            fit(c.main, mainText, tmp, mainSize, fMedium, Paint.Align.CENTER)
        }
        tmp.set(x0 + inset, y0 + inset * 0.6f, x0 + inset + (w - inset * 2) * 0.55f, y0 + inset * 0.6f + small * 1.3f)
        fit(c.top, lg.top, tmp, small, fRegular, Paint.Align.LEFT)
        tmp.set(x0 + w * 0.45f, y0 + inset * 0.5f, x0 + w - inset, y0 + inset * 0.5f + altTopSize * 1.3f)
        fit(c.altTop, lg.altTop, tmp, altTopSize, fSemibold, Paint.Align.RIGHT)
        val ay = y0 + h - inset * 0.5f - altSize * 1.25f
        tmp.set(x0 + w * (if (bigAlt) 0.36f else 0.2f), ay, x0 + w - inset * 0.8f, ay + altSize * 1.25f)
        fit(c.alt, lg.alt, tmp, altSize, fSemibold, Paint.Align.RIGHT)
        val fy = y0 + h - inset * 0.6f - small * 1.3f
        tmp.set(x0 + inset, fy, x0 + inset + (w - inset * 2) * (if (lg.alt.isEmpty()) 1f else 0.5f), fy + small * 1.3f)
        fit(c.fn, c.fnHint, tmp, max(small * 0.85f, 7.5f * dp), fSemibold, Paint.Align.LEFT)
        c.ledBox.set(x0 + w - inset - 6 * dp, y0 + inset, x0 + w - inset, y0 + inset + 6 * dp)
        c.radius = min(10 * dp, unit * 0.16f)
    }

    // MARK: drawing

    override fun onDraw(canvas: Canvas) {
        val t = theme
        canvas.drawColor(t.bg)
        for (c in caps) drawCap(canvas, c, t)
    }

    private fun drawCap(canvas: Canvas, c: Cap, t: KTheme) {
        val r = c.rect
        if (r.width() <= 0) return
        val base = when (c.style) {
            KeyStyle.MOD, KeyStyle.AUTO -> t.keyMod
            KeyStyle.ACCENT -> t.keyAccent
            KeyStyle.DANGER -> t.keyDanger
            KeyStyle.NORMAL -> t.key
        }
        if (t.shadow && !c.pressed) {
            fill.color = Color.argb(if (t.isLight) 46 else 90, 0, 0, 0)
            tmp.set(r.left, r.top + 1.5f * dp, r.right, r.bottom + 1.5f * dp)
            canvas.drawRoundRect(tmp, c.radius, c.radius, fill)
        }
        fill.color = if (c.pressed) t.pressed else if (c.fnLayer) KTheme.blend(base, t.latched, 0.22f) else base
        canvas.drawRoundRect(r, c.radius, c.radius, fill)
        if (c.latched && !c.pressed) {
            stroke.color = t.latched
            stroke.strokeWidth = 2 * dp
            tmp.set(r); tmp.inset(dp, dp)
            canvas.drawRoundRect(tmp, c.radius, c.radius, stroke)
        } else if (Color.alpha(t.border) > 0) {
            stroke.color = t.border
            stroke.strokeWidth = max(1f, dp * 0.6f)
            canvas.drawRoundRect(r, c.radius, c.radius, stroke)
        }
        val accentText = c.style == KeyStyle.ACCENT || c.style == KeyStyle.DANGER
        val fg = if (c.pressed) (if (t.isLight) Color.WHITE else Color.rgb(10, 10, 10)) else if (accentText) Color.WHITE else t.text

        c.led?.let { on ->
            fill.color = if (on) t.latched else KTheme.alpha(t.textDim, 0.25f)
            canvas.drawCircle(c.ledBox.centerX(), c.ledBox.centerY(), c.ledBox.width() / 2, fill)
        }
        drawLabel(canvas, c.main, fMedium, fg)
        drawLabel(canvas, c.top, fRegular, if (c.pressed) KTheme.alpha(fg, 0.8f) else t.textDim)
        drawLabel(canvas, c.fn, fSemibold, if (c.pressed) KTheme.alpha(fg, 0.8f) else KTheme.alpha(t.latched, 0.85f))
        drawLabel(canvas, c.alt, fSemibold, if (c.pressed) KTheme.alpha(fg, 0.8f) else KTheme.alpha(t.accent, 0.9f))
        drawLabel(canvas, c.altTop, fSemibold, if (c.pressed) KTheme.alpha(fg, 0.75f) else KTheme.alpha(t.accent, 0.75f))
        c.icon?.let { drawIcon(canvas, it, c.iconBox, fg) }
    }

    private fun drawLabel(canvas: Canvas, l: Label, face: Typeface, color: Int) {
        if (l.text.isEmpty() || l.size <= 0f) return
        textPaint.typeface = face
        textPaint.textSize = l.size
        textPaint.textAlign = l.align
        textPaint.color = color
        canvas.drawText(l.text, l.x, l.y, textPaint)
    }

    private fun drawIcon(canvas: Canvas, name: String, b: RectF, color: Int) {
        val s = b.width()
        val cx = b.centerX()
        val cy = b.centerY()
        fill.color = color
        stroke.color = color
        path.reset()
        when (name) {
            "up", "down", "left", "right" -> {
                val a = s * 0.3f
                when (name) {
                    "up" -> { path.moveTo(cx, cy - a); path.lineTo(cx + a, cy + a * 0.7f); path.lineTo(cx - a, cy + a * 0.7f) }
                    "down" -> { path.moveTo(cx, cy + a); path.lineTo(cx + a, cy - a * 0.7f); path.lineTo(cx - a, cy - a * 0.7f) }
                    "left" -> { path.moveTo(cx - a, cy); path.lineTo(cx + a * 0.7f, cy - a); path.lineTo(cx + a * 0.7f, cy + a) }
                    else -> { path.moveTo(cx + a, cy); path.lineTo(cx - a * 0.7f, cy - a); path.lineTo(cx - a * 0.7f, cy + a) }
                }
                path.close()
                canvas.drawPath(path, fill)
            }
            "backspace" -> {
                val hw = s * 0.45f
                val hh = s * 0.3f
                stroke.strokeWidth = max(1.5f * dp, s * 0.07f)
                stroke.strokeJoin = Paint.Join.ROUND
                stroke.strokeCap = Paint.Cap.ROUND
                path.moveTo(cx - hw, cy)
                path.lineTo(cx - hw * 0.45f, cy - hh)
                path.lineTo(cx + hw, cy - hh)
                path.lineTo(cx + hw, cy + hh)
                path.lineTo(cx - hw * 0.45f, cy + hh)
                path.close()
                val xc = cx + hw * 0.28f
                val xs = hh * 0.45f
                path.moveTo(xc - xs, cy - xs); path.lineTo(xc + xs, cy + xs)
                path.moveTo(xc + xs, cy - xs); path.lineTo(xc - xs, cy + xs)
                canvas.drawPath(path, stroke)
            }
            "win" -> {
                val q = s * 0.2f
                val g = s * 0.05f
                for (dx in listOf(-1, 1)) for (dy in listOf(-1, 1)) {
                    val l = if (dx < 0) cx - g / 2 - q else cx + g / 2
                    val tp = if (dy < 0) cy - g / 2 - q else cy + g / 2
                    canvas.drawRect(l, tp, l + q, tp + q, fill)
                }
            }
            "menu" -> {
                stroke.strokeWidth = max(1.5f * dp, s * 0.07f)
                stroke.strokeCap = Paint.Cap.ROUND
                val hw = s * 0.28f
                for (i in -1..1) canvas.drawLine(cx - hw, cy + i * s * 0.18f, cx + hw, cy + i * s * 0.18f, stroke)
            }
        }
        stroke.strokeCap = Paint.Cap.BUTT
    }

    // MARK: actions

    private val fnMenu = Runnable {
        if (fnHeld > 0 && fnSolo) {
            performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
            releaseAllTouches()
            onMenu?.invoke()
        }
    }

    private fun feedback() {
        if (Settings.haptics) performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        if (Settings.keySound) audio?.playSoundEffect(AudioManager.FX_KEYPRESS_STANDARD, 0.5f)
    }

    private fun keyDown(c: Cap, a: KeyAction) {
        c.pressCount++
        feedback()
        if (!(a is KeyAction.Sp && a.special == Special.FN)) fnSolo = false
        when (a) {
            is KeyAction.Key -> input.touchDown(a.code)
            is KeyAction.Sp -> when (a.special) {
                Special.FN -> {
                    fnHeld++
                    if (fnHeld == 1) {
                        fnSolo = true
                        postDelayed(fnMenu, 900)
                    }
                    updateLegends(resolve = false)
                }
                Special.LANG_SWITCH -> input.tapCombo(listOf(Keys.LWIN, Keys.SPACE))
                Special.RELEASE_ALL -> { releaseAllTouches(); input.releaseAll() }
                Special.TEXT_PANEL -> {}
            }
        }
        refreshStates()
    }

    private fun keyUp(c: Cap, a: KeyAction) {
        if (c.pressCount > 0) c.pressCount--
        when (a) {
            is KeyAction.Key -> input.touchUp(a.code)
            is KeyAction.Sp -> when (a.special) {
                Special.FN -> {
                    fnHeld = max(0, fnHeld - 1)
                    if (fnHeld == 0) removeCallbacks(fnMenu)
                    updateLegends(resolve = false)
                }
                Special.TEXT_PANEL -> onSpecial?.invoke(Special.TEXT_PANEL)
                else -> {}
            }
        }
        refreshStates()
    }

    /** Releases everything this view is holding (app background, focus loss, freeze recovery...). */
    fun releaseAllTouches() {
        for (i in 0 until bindings.size()) {
            val (idx, fn) = bindings.valueAt(i)
            if (idx < 0) continue
            val c = caps[idx]
            val a = actionOf(c.def, fn)
            if (a is KeyAction.Sp && a.special == Special.FN) continue
            keyUp(c, a)
        }
        bindings.clear()
        removeCallbacks(fnMenu)
        val hadFn = fnHeld > 0
        fnHeld = 0
        fnSolo = false
        for (c in caps) c.pressCount = 0
        if (hadFn) updateLegends(resolve = false)
        refreshStates()
    }

    // MARK: touches

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // Deliver touches as they arrive instead of batched per frame: lower key latency.
                requestUnbufferedDispatch(e)
                begin(e.getPointerId(0), e.getX(0), e.getY(0))
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                val i = e.actionIndex
                begin(e.getPointerId(i), e.getX(i), e.getY(i))
            }
            MotionEvent.ACTION_POINTER_UP -> end(e.getPointerId(e.actionIndex))
            MotionEvent.ACTION_UP -> {
                end(e.getPointerId(e.actionIndex))
                // Last finger up: nothing can still be held by a touch.
                if (bindings.size() > 0) releaseAllTouches()
            }
            MotionEvent.ACTION_CANCEL -> releaseAllTouches()
        }
        return true
    }

    private fun begin(id: Int, x: Float, y: Float) {
        bindings[id]?.let { end(id) }
        val idx = element(x, y)
        if (idx < 0) {
            bindings.put(id, -1 to false)
            return
        }
        val c = caps[idx]
        val fn = fnHeld > 0 && c.def.fn != null
        bindings.put(id, idx to fn)
        keyDown(c, actionOf(c.def, fn))
    }

    private fun end(id: Int) {
        val b = bindings[id] ?: return
        bindings.remove(id)
        if (b.first < 0) return
        val c = caps[b.first]
        keyUp(c, actionOf(c.def, b.second))
    }
}
