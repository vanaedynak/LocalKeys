package com.localkeys.app

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.DashPathEffect
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.media.AudioManager
import android.os.Build
import android.os.SystemClock
import android.util.SparseArray
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Cockpit controller surface for Microsoft Flight Simulator 2020 (default keybinds + RMB mouse
 * freelook, or optional vJoy analog mode). Drawn on a single Canvas with per-pointer multitouch.
 */
@SuppressLint("ViewConstructor")
class FlightView(ctx: Context) : View(ctx) {
    private val dp = resources.displayMetrics.density
    var theme = KTheme.byId(Settings.themeId)
        set(v) { field = v; invalidate() }

    var onMenu: (() -> Unit)? = null

    private enum class Kind {
        THROTTLE, STICK, RUDDER, CAMERA_PAD,
        MENU, KEY, COMBO, ZOOM, CENTER, TILT_TOGGLE, RELEASE_ALL
    }

    private inner class Zone(
        val gx: Float, val gy: Float, val gw: Float, val gh: Float,
        val kind: Kind,
        val title: String,
        val subtitle: String = "",
        val style: KeyStyle = KeyStyle.MOD,
        val code: Int = 0,
        val combo: IntArray = intArrayOf(),
        val wheelDelta: Int = 0,
    ) {
        val cell = RectF()
        val rect = RectF()
        var pressCount = 0
        var radius = 10 * dp
    }

    private val zones = ArrayList<Zone>().apply {
        // Left column: Throttle
        add(Zone(0f, 0f, 2.2f, 7.4f, Kind.THROTTLE, "ГАЗ", "РУД", KeyStyle.NORMAL))

        // Top utility strip
        add(Zone(2.2f, 0f, 1.5f, 1.2f, Kind.MENU, "Меню", "Пресеты", KeyStyle.MOD))
        add(Zone(3.7f, 0f, 1.1f, 1.2f, Kind.KEY, "Esc", "Меню игры", KeyStyle.MOD, Keys.ESC))
        add(Zone(4.8f, 0f, 1.4f, 1.2f, Kind.KEY, "Пауза", "Акт.", KeyStyle.MOD, Keys.PAUSE))
        add(Zone(6.2f, 0f, 1.8f, 1.2f, Kind.TILT_TOGGLE, "Наклон", "Гиро", KeyStyle.MOD))
        add(Zone(8.0f, 0f, 1.8f, 1.2f, Kind.CENTER, "Центр", "Num5", KeyStyle.MOD))

        // Camera freelook pad + view controls
        add(Zone(2.2f, 1.2f, 5.0f, 3.1f, Kind.CAMERA_PAD, "ОБЗОР КАМЕРОЙ", "тяни — крутить · 2× — сброс", KeyStyle.NORMAL))
        add(Zone(2.2f, 4.3f, 2.1f, 1.3f, Kind.KEY, "Камера", "Внутр / Снар", KeyStyle.MOD, Keys.END))
        add(Zone(4.3f, 4.3f, 1.45f, 1.3f, Kind.ZOOM, "Зум −", "Колесо", KeyStyle.MOD, wheelDelta = -120))
        add(Zone(5.75f, 4.3f, 1.45f, 1.3f, Kind.ZOOM, "Зум +", "Колесо", KeyStyle.MOD, wheelDelta = 120))

        // Secondary aircraft systems (Flaps, Trim, Spoilers, Autopilot)
        add(Zone(7.2f, 1.2f, 1.3f, 1.45f, Kind.KEY, "Закр. −", "F6", KeyStyle.NORMAL, Keys.f(6)))
        add(Zone(8.5f, 1.2f, 1.3f, 1.45f, Kind.KEY, "Закр. +", "F7", KeyStyle.NORMAL, Keys.f(7)))
        add(Zone(7.2f, 2.65f, 1.3f, 1.45f, Kind.KEY, "Трим. ↓", "Num 7", KeyStyle.NORMAL, Keys.NUM_7))
        add(Zone(8.5f, 2.65f, 1.3f, 1.45f, Kind.KEY, "Трим. ↑", "Num 1", KeyStyle.NORMAL, Keys.NUM_1))
        add(Zone(7.2f, 4.10f, 1.3f, 1.50f, Kind.KEY, "Спойл.", "Num /", KeyStyle.NORMAL, Keys.NUM_DIV))
        add(Zone(8.5f, 4.10f, 1.3f, 1.50f, Kind.KEY, "Автоп.", "Z", KeyStyle.NORMAL, Keys.Z))

        // Primary brakes & landing gear
        add(Zone(2.2f, 5.6f, 2.9f, 1.8f, Kind.KEY, "ТОРМОЗ", "Num . · удерж.", KeyStyle.DANGER, Keys.NUM_DOT))
        add(Zone(5.1f, 5.6f, 2.2f, 1.8f, Kind.COMBO, "Стоян.", "Ctrl+Num .", KeyStyle.MOD, combo = intArrayOf(Keys.LCTRL, Keys.NUM_DOT)))
        add(Zone(7.3f, 5.6f, 2.5f, 1.8f, Kind.KEY, "Шасси", "G", KeyStyle.ACCENT, Keys.G))

        // Right side: Flight stick
        add(Zone(9.8f, 0f, 6.2f, 7.4f, Kind.STICK, "ШТУРВАЛ", "2× тап — центр", KeyStyle.NORMAL))

        // Bottom row: Rudder pedals + quick flaps/view/release
        add(Zone(0f, 7.4f, 9.8f, 1.6f, Kind.RUDDER, "ПЕДАЛИ", "Рыскание", KeyStyle.NORMAL))
        add(Zone(9.8f, 7.4f, 1.55f, 1.6f, Kind.KEY, "Закр. 0", "F5", KeyStyle.MOD, Keys.f(5)))
        add(Zone(11.35f, 7.4f, 1.65f, 1.6f, Kind.KEY, "Закр. MAX", "F8", KeyStyle.MOD, Keys.f(8)))
        add(Zone(13.0f, 7.4f, 1.7f, 1.6f, Kind.COMBO, "Сброс вида", "Ctrl+Проб", KeyStyle.MOD, combo = intArrayOf(Keys.LCTRL, Keys.SPACE)))
        add(Zone(14.7f, 7.4f, 1.3f, 1.6f, Kind.RELEASE_ALL, "Отп.", "Сброс", KeyStyle.MOD))
    }

    private val throttleZone = zones.first { it.kind == Kind.THROTTLE }
    private val stickZone = zones.first { it.kind == Kind.STICK }
    private val rudderZone = zones.first { it.kind == Kind.RUDDER }
    private val cameraZone = zones.first { it.kind == Kind.CAMERA_PAD }

    private val numLockChip = RectF()
    private var showNumLockChip = false

    private data class Binding(
        val zoneIdx: Int,
        var startX: Float,
        var startY: Float,
        var lastX: Float,
        var lastY: Float,
        var startVal: Float = 0f,
        var camFracX: Float = 0f,
        var camFracY: Float = 0f,
        var downAt: Long = 0L,
        var movedDist: Float = 0f,
        var isNumLockChip: Boolean = false,
    )

    private val bindings = SparseArray<Binding>()

    private var stickX = 0f
    private var stickY = 0f
    private var throttleVal = 0f
    private var rudderVal = 0f
    private var lastStickTapAt = 0L
    private var lastCamTapAt = 0L
    private var stickTouched = false
    private var rudderTouched = false
    private var throttleTouched = false
    private var camTouched = false

    private val fill = Paint(Paint.ANTI_ALIAS_FLAG)
    private val stroke = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.STROKE }
    private val dashStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        pathEffect = DashPathEffect(floatArrayOf(6 * dp, 5 * dp), 0f)
    }
    private val textPaint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.SUBPIXEL_TEXT_FLAG)
    private val fMedium = Typeface.create("sans-serif-medium", Typeface.NORMAL)
    private val fRegular = Typeface.DEFAULT
    private val fSemibold = if (Build.VERSION.SDK_INT >= 28) Typeface.create(Typeface.DEFAULT, 600, false) else fMedium
    private val fMono = Typeface.create(Typeface.MONOSPACE, Typeface.BOLD)
    private val tmp = RectF()
    private val path = Path()
    private val audio = ctx.getSystemService(AudioManager::class.java)

    private var ux = 1f
    private var uy = 1f
    private var unit = 1f

    init {
        isHapticFeedbackEnabled = true
        FlightController.init(ctx)
        FlightController.onTiltUpdate = { rx, ry ->
            if (!stickTouched && FlightController.tiltEnabled) {
                stickX = rx
                stickY = ry
                FlightController.engine.setStick(rx, ry, abs(rx) > 0.04f || abs(ry) > 0.04f)
                invalidate()
            }
        }
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        FlightController.startLoop()
    }

    override fun onDetachedFromWindow() {
        releaseAllTouches()
        FlightController.stopLoop()
        super.onDetachedFromWindow()
    }

    private fun shouldWarnNumLock(): Boolean =
        Settings.msfsInputMode != "vjoy" && ConnectionManager.pcState?.let { !it.num } == true

    fun updatePcStatus() {
        showNumLockChip = shouldWarnNumLock()
        invalidate()
    }

    override fun onLayout(changed: Boolean, l: Int, t: Int, r: Int, b: Int) {
        super.onLayout(changed, l, t, r, b)
        relayout()
    }

    fun relayout() {
        if (width == 0 || height == 0) return
        val pad = 4 * dp
        val availW = max(width - paddingLeft - paddingRight - pad * 2, 1f)
        val availH = max(height - paddingTop - paddingBottom - pad * 2, 1f)
        ux = availW / 16f
        uy = availH / 9f
        unit = min(ux, uy)
        val ox = paddingLeft + pad
        val oy = paddingTop + pad
        val gap = max(3 * dp, Settings.keyGap * dp)

        for (z in zones) {
            z.cell.set(ox + z.gx * ux, oy + z.gy * uy, ox + (z.gx + z.gw) * ux, oy + (z.gy + z.gh) * uy)
            z.rect.set(z.cell)
            z.rect.inset(gap / 2f, gap / 2f)
            z.radius = min(14 * dp, min(z.rect.width(), z.rect.height()) * 0.22f)
        }
        val sr = stickZone.rect
        val cw = min(sr.width() * 0.86f, 220 * dp)
        val ch = 26 * dp
        numLockChip.set(sr.centerX() - cw / 2f, sr.top + 8 * dp, sr.centerX() + cw / 2f, sr.top + 8 * dp + ch)

        if (Build.VERSION.SDK_INT >= 29) {
            val h = (180 * dp).toInt()
            val w = (36 * dp).toInt()
            systemGestureExclusionRects = listOf(Rect(0, height - h, w, height), Rect(width - w, height - h, width, height))
        }
        invalidate()
    }

    // MARK: drawing

    override fun onDraw(canvas: Canvas) {
        val t = theme
        canvas.drawColor(t.bg)
        updatePcStatusFlag()

        for (z in zones) {
            when (z.kind) {
                Kind.THROTTLE -> drawThrottle(canvas, z, t)
                Kind.STICK -> drawStick(canvas, z, t)
                Kind.RUDDER -> drawRudder(canvas, z, t)
                Kind.CAMERA_PAD -> drawCameraPad(canvas, z, t)
                else -> drawButton(canvas, z, t)
            }
        }
    }

    private fun updatePcStatusFlag() {
        showNumLockChip = shouldWarnNumLock()
    }

    private fun cardSurface(canvas: Canvas, r: RectF, radius: Float, baseColor: Int, pressed: Boolean, latched: Boolean, t: KTheme) {
        if (t.shadow && !pressed) {
            fill.color = Color.argb(if (t.isLight) 42 else 85, 0, 0, 0)
            tmp.set(r.left, r.top + 1.5f * dp, r.right, r.bottom + 1.5f * dp)
            canvas.drawRoundRect(tmp, radius, radius, fill)
        }
        fill.color = baseColor
        canvas.drawRoundRect(r, radius, radius, fill)
        if (latched) {
            stroke.color = t.latched
            stroke.strokeWidth = 2 * dp
            tmp.set(r); tmp.inset(dp, dp)
            canvas.drawRoundRect(tmp, radius, radius, stroke)
        } else if (Color.alpha(t.border) > 0) {
            stroke.color = t.border
            stroke.strokeWidth = max(1f, dp * 0.65f)
            canvas.drawRoundRect(r, radius, radius, stroke)
        }
    }

    private fun drawButton(canvas: Canvas, z: Zone, t: KTheme) {
        val r = z.rect
        if (r.width() <= 0 || r.height() <= 0) return
        val isPressed = z.pressCount > 0
        val isLatched = z.kind == Kind.TILT_TOGGLE && FlightController.tiltEnabled
        val base = when (z.style) {
            KeyStyle.MOD, KeyStyle.AUTO -> t.keyMod
            KeyStyle.ACCENT -> t.keyAccent
            KeyStyle.DANGER -> t.keyDanger
            KeyStyle.NORMAL -> t.key
        }
        val bg = if (isPressed) t.pressed else if (isLatched) KTheme.blend(base, t.latched, 0.22f) else base
        cardSurface(canvas, r, z.radius, bg, isPressed, isLatched, t)

        val accentText = z.style == KeyStyle.ACCENT || z.style == KeyStyle.DANGER
        val fg = if (isPressed) (if (t.isLight) Color.WHITE else Color.rgb(10, 10, 10)) else if (accentText) Color.WHITE else t.text
        val subFg = if (isPressed) KTheme.alpha(fg, 0.8f) else if (accentText) Color.argb(200, 255, 255, 255) else t.textDim

        val padX = 6 * dp
        val maxW = max(r.width() - padX * 2, 1f)
        val hasSub = z.subtitle.isNotEmpty()
        val mainSize = fittedTextSize(z.title, maxW, min(r.height() * 0.36f, 15.5f * dp), fMedium)
        textPaint.typeface = fMedium
        textPaint.textSize = mainSize
        textPaint.textAlign = Paint.Align.CENTER
        textPaint.color = fg

        if (hasSub) {
            val subSize = fittedTextSize(z.subtitle, maxW, min(r.height() * 0.24f, 10.5f * dp), fRegular)
            val fmMain = textPaint.fontMetrics
            val mainY = r.centerY() - subSize * 0.32f - (fmMain.ascent + fmMain.descent) / 2f
            canvas.drawText(z.title, r.centerX(), mainY, textPaint)

            textPaint.typeface = fRegular
            textPaint.textSize = subSize
            textPaint.color = subFg
            val fmSub = textPaint.fontMetrics
            val subY = r.centerY() + mainSize * 0.58f - (fmSub.ascent + fmSub.descent) / 2f
            canvas.drawText(z.subtitle, r.centerX(), subY, textPaint)
        } else {
            val fm = textPaint.fontMetrics
            canvas.drawText(z.title, r.centerX(), r.centerY() - (fm.ascent + fm.descent) / 2f, textPaint)
        }
    }

    private fun drawThrottle(canvas: Canvas, z: Zone, t: KTheme) {
        val r = z.rect
        val bg = if (throttleTouched) KTheme.blend(t.keyMod, t.accent, 0.12f) else t.keyMod
        cardSurface(canvas, r, z.radius, bg, pressed = false, latched = false, t)

        val topPad = 40 * dp
        val botPad = 14 * dp
        val trackTop = r.top + topPad
        val trackBot = r.bottom - botPad
        val trackH = max(trackBot - trackTop, 1f)
        val yPos = trackBot - throttleVal * trackH

        // Fill from bottom up to throttle position
        canvas.save()
        path.reset()
        path.addRoundRect(r, z.radius, z.radius, Path.Direction.CW)
        canvas.clipPath(path)

        fill.color = KTheme.alpha(t.accent, 0.25f)
        canvas.drawRect(r.left, yPos, r.right, r.bottom, fill)

        // Detent ticks (0%, 25%, 50%, 75%, 100%)
        stroke.color = KTheme.alpha(t.textDim, 0.28f)
        stroke.strokeWidth = 1 * dp
        for (step in 0..4) {
            val ty = trackBot - (step / 4f) * trackH
            val tw = if (step == 0 || step == 4 || step == 2) r.width() * 0.28f else r.width() * 0.16f
            canvas.drawLine(r.left + 8 * dp, ty, r.left + 8 * dp + tw, ty, stroke)
            canvas.drawLine(r.right - 8 * dp - tw, ty, r.right - 8 * dp, ty, stroke)
        }

        // Tactile lever bar
        val leverH = 10 * dp
        tmp.set(r.left + 6 * dp, yPos - leverH / 2f, r.right - 6 * dp, yPos + leverH / 2f)
        fill.color = t.accent
        canvas.drawRoundRect(tmp, leverH / 2f, leverH / 2f, fill)
        fill.color = Color.argb(190, 255, 255, 255)
        canvas.drawLine(tmp.left + 8 * dp, yPos, tmp.right - 8 * dp, yPos, stroke.apply { color = Color.argb(170, 255, 255, 255); strokeWidth = 1.5f * dp })
        canvas.restore()

        // Title & tabular percentage at top
        textPaint.textAlign = Paint.Align.CENTER
        textPaint.typeface = fSemibold
        textPaint.textSize = 11.5f * dp
        textPaint.color = t.textDim
        canvas.drawText("ГАЗ (РУД)", r.centerX(), r.top + 16 * dp, textPaint)

        val pct = (throttleVal * 100f).roundToInt()
        val pctLabel = "$pct%"
        textPaint.typeface = fMono
        textPaint.textSize = 14f * dp
        textPaint.color = if (pct >= 98) t.latched else t.text
        canvas.drawText(pctLabel, r.centerX(), r.top + 33 * dp, textPaint)
    }

    private fun drawRudder(canvas: Canvas, z: Zone, t: KTheme) {
        val r = z.rect
        val bg = if (rudderTouched) KTheme.blend(t.keyMod, t.accent, 0.12f) else t.keyMod
        cardSurface(canvas, r, z.radius, bg, pressed = false, latched = false, t)

        val padX = 14 * dp
        val trackL = r.left + padX
        val trackR = r.right - padX
        val midX = (trackL + trackR) / 2f
        val halfW = max((trackR - trackL) / 2f, 1f)
        val xPos = midX + rudderVal * halfW

        canvas.save()
        path.reset()
        path.addRoundRect(r, z.radius, z.radius, Path.Direction.CW)
        canvas.clipPath(path)

        // Fill from center toward rudder deflection
        fill.color = KTheme.alpha(t.accent, 0.28f)
        canvas.drawRect(min(midX, xPos), r.top, max(midX, xPos), r.bottom, fill)

        // Center notch
        stroke.color = KTheme.alpha(t.textDim, 0.35f)
        stroke.strokeWidth = 1.5f * dp
        canvas.drawLine(midX, r.top + 6 * dp, midX, r.bottom - 6 * dp, stroke)

        // Handle bar
        val hw = 8 * dp
        tmp.set(xPos - hw / 2f, r.top + 5 * dp, xPos + hw / 2f, r.bottom - 5 * dp)
        fill.color = t.accent
        canvas.drawRoundRect(tmp, hw / 2f, hw / 2f, fill)
        canvas.restore()

        val fm = textPaint.run {
            typeface = fMedium
            textSize = 12 * dp
            fontMetrics
        }
        val cy = r.centerY() - (fm.ascent + fm.descent) / 2f
        textPaint.color = t.textDim
        textPaint.textAlign = Paint.Align.LEFT
        canvas.drawText("◀ ЛЕВ.", r.left + 12 * dp, cy, textPaint)
        textPaint.textAlign = Paint.Align.RIGHT
        canvas.drawText("ПРАВ. ▶", r.right - 12 * dp, cy, textPaint)

        val pct = (rudderVal * 100f).roundToInt()
        val centerTxt = if (pct == 0) "ПЕДАЛИ · 0" else String.format("ПЕДАЛИ · %+d", pct)
        textPaint.typeface = fSemibold
        textPaint.textSize = 12 * dp
        textPaint.textAlign = Paint.Align.CENTER
        textPaint.color = t.text
        canvas.drawText(centerTxt, r.centerX(), cy, textPaint)
    }

    private fun drawCameraPad(canvas: Canvas, z: Zone, t: KTheme) {
        val r = z.rect
        val bg = if (camTouched) KTheme.blend(t.keyMod, t.accent, 0.14f) else KTheme.blend(t.bg, t.keyMod, 0.72f)
        cardSurface(canvas, r, z.radius, bg, pressed = false, latched = false, t)

        // Subtle viewfinder corner brackets
        val b = 10 * dp
        val ins = 9 * dp
        stroke.color = KTheme.alpha(t.accent, if (camTouched) 0.75f else 0.35f)
        stroke.strokeWidth = 1.5f * dp
        path.reset()
        // TL
        path.moveTo(r.left + ins, r.top + ins + b); path.lineTo(r.left + ins, r.top + ins); path.lineTo(r.left + ins + b, r.top + ins)
        // TR
        path.moveTo(r.right - ins - b, r.top + ins); path.lineTo(r.right - ins, r.top + ins); path.lineTo(r.right - ins, r.top + ins + b)
        // BL
        path.moveTo(r.left + ins, r.bottom - ins - b); path.lineTo(r.left + ins, r.bottom - ins); path.lineTo(r.left + ins + b, r.bottom - ins)
        // BR
        path.moveTo(r.right - ins - b, r.bottom - ins); path.lineTo(r.right - ins, r.bottom - ins); path.lineTo(r.right - ins, r.bottom - ins - b)
        canvas.drawPath(path, stroke)

        // Center subtle reticle
        val cx = r.centerX()
        val cy = r.centerY()
        val cr = 9 * dp
        stroke.color = KTheme.alpha(t.textDim, 0.3f)
        canvas.drawCircle(cx, cy, cr, stroke)
        canvas.drawLine(cx - cr * 1.5f, cy, cx + cr * 1.5f, cy, stroke)
        canvas.drawLine(cx, cy - cr * 1.5f, cx, cy + cr * 1.5f, stroke)

        textPaint.textAlign = Paint.Align.CENTER
        textPaint.typeface = fSemibold
        textPaint.textSize = 12 * dp
        textPaint.color = t.text
        canvas.drawText(z.title, cx, r.top + 21 * dp, textPaint)

        textPaint.typeface = fRegular
        textPaint.textSize = 10.5f * dp
        textPaint.color = t.textDim
        canvas.drawText(z.subtitle, cx, r.bottom - 10 * dp, textPaint)
    }

    private fun drawStick(canvas: Canvas, z: Zone, t: KTheme) {
        val r = z.rect
        val bg = if (stickTouched) KTheme.blend(t.keyMod, t.accent, 0.10f) else KTheme.blend(t.bg, t.keyMod, 0.78f)
        cardSurface(canvas, r, z.radius, bg, pressed = false, latched = FlightController.tiltEnabled, t)

        val cx = r.centerX()
        val cy = r.centerY()
        val travel = stickTravel(r)

        // Crosshair
        stroke.color = KTheme.alpha(t.textDim, 0.25f)
        stroke.strokeWidth = 1.2f * dp
        canvas.drawLine(cx - travel, cy, cx + travel, cy, stroke)
        canvas.drawLine(cx, cy - travel, cx, cy + travel, stroke)

        // Deadzone ring & outer boundary
        stroke.color = KTheme.alpha(t.textDim, 0.22f)
        canvas.drawCircle(cx, cy, travel * 0.14f, stroke)

        dashStroke.color = KTheme.alpha(t.accent, 0.35f)
        dashStroke.strokeWidth = 1.4f * dp
        tmp.set(cx - travel, cy - travel, cx + travel, cy + travel)
        canvas.drawRoundRect(tmp, travel * 0.28f, travel * 0.28f, dashStroke)

        // Cardinal hints inside box
        textPaint.typeface = fRegular
        textPaint.textSize = 9f * dp
        textPaint.color = KTheme.alpha(t.textDim, 0.78f)
        textPaint.textAlign = Paint.Align.CENTER
        val topHintY = if (showNumLockChip) r.top + 46 * dp else r.top + 16 * dp
        canvas.drawText("▲ ОТ СЕБЯ", cx, topHintY, textPaint)
        canvas.drawText("▼ НА СЕБЯ", cx, r.bottom - 24 * dp, textPaint)

        textPaint.textAlign = Paint.Align.LEFT
        canvas.drawText("◀ КРЕН", r.left + 6 * dp, cy - 9 * dp, textPaint)
        textPaint.textAlign = Paint.Align.RIGHT
        canvas.drawText("КРЕН ▶", r.right - 6 * dp, cy - 9 * dp, textPaint)

        // Deflection vector & puck
        val kx = cx + stickX * travel
        val ky = cy + stickY * travel
        if (abs(stickX) > 0.02f || abs(stickY) > 0.02f) {
            stroke.color = KTheme.alpha(t.accent, 0.65f)
            stroke.strokeWidth = 2.5f * dp
            canvas.drawLine(cx, cy, kx, ky, stroke)
        }

        val puckR = max(min(r.width(), r.height()) * 0.085f, 15 * dp)
        fill.color = Color.argb(90, 0, 0, 0)
        canvas.drawCircle(kx, ky + 2 * dp, puckR, fill)
        fill.color = KTheme.alpha(t.accent, 0.92f)
        canvas.drawCircle(kx, ky, puckR, fill)
        stroke.color = Color.argb(210, 255, 255, 255)
        stroke.strokeWidth = 2 * dp
        canvas.drawCircle(kx, ky, puckR - dp, stroke)

        // Bottom caption & status
        val caption = when {
            Settings.msfsInputMode == "vjoy" && ConnectionManager.pcState?.joystick != "ok" ->
                "vJoy не найден на ПК · перекл. в Меню"
            FlightController.tiltEnabled -> "НАКЛОН ТЕЛЕФОНА · 2× тап — центр"
            else -> "ШТУРВАЛ · 2× тап — центр"
        }
        textPaint.typeface = fSemibold
        textPaint.textSize = 10.5f * dp
        textPaint.textAlign = Paint.Align.CENTER
        textPaint.color = if (Settings.msfsInputMode == "vjoy" && ConnectionManager.pcState?.joystick != "ok") t.latched else t.textDim
        canvas.drawText(caption, cx, r.bottom - 8 * dp, textPaint)

        // NumLock warning chip
        if (showNumLockChip) {
            fill.color = KTheme.alpha(t.latched, 0.22f)
            canvas.drawRoundRect(numLockChip, numLockChip.height() / 2f, numLockChip.height() / 2f, fill)
            stroke.color = t.latched
            stroke.strokeWidth = 1.2f * dp
            canvas.drawRoundRect(numLockChip, numLockChip.height() / 2f, numLockChip.height() / 2f, stroke)
            textPaint.typeface = fSemibold
            textPaint.textSize = 11 * dp
            textPaint.color = t.latched
            val fm = textPaint.fontMetrics
            canvas.drawText("⚠ NumLock ВЫКЛ — вкл.", numLockChip.centerX(), numLockChip.centerY() - (fm.ascent + fm.descent) / 2f, textPaint)
        }
    }

    private fun stickTravel(r: RectF): Float = min(r.width() * 0.31f, r.height() * 0.34f)

    private fun fittedTextSize(text: String, maxW: Float, maxH: Float, face: Typeface): Float {
        textPaint.typeface = face
        textPaint.textSize = maxH
        val w = textPaint.measureText(text)
        return if (w > maxW) max(maxH * maxW / w, 8 * dp) else maxH
    }

    // MARK: touches

    private fun feedback(strong: Boolean = false) {
        if (Settings.haptics) {
            performHapticFeedback(if (strong) HapticFeedbackConstants.LONG_PRESS else HapticFeedbackConstants.KEYBOARD_TAP)
        }
        if (Settings.keySound) audio?.playSoundEffect(AudioManager.FX_KEYPRESS_STANDARD, 0.5f)
    }

    private fun hitZone(x: Float, y: Float): Int {
        for (i in zones.indices) {
            if (zones[i].rect.contains(x, y)) return i
        }
        // Small slack to nearest button/zone
        var best = -1
        var bestD = 12 * dp
        for (i in zones.indices) {
            val r = zones[i].rect
            val dx = max(0f, max(r.left - x, x - r.right))
            val dy = max(0f, max(r.top - y, y - r.bottom))
            val d = kotlin.math.hypot(dx, dy)
            if (d < bestD) { bestD = d; best = i }
        }
        return best
    }

    @SuppressLint("ClickableViewAccessibility")
    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                requestUnbufferedDispatch(e)
                begin(e.getPointerId(0), e.getX(0), e.getY(0))
            }
            MotionEvent.ACTION_POINTER_DOWN -> {
                val idx = e.actionIndex
                begin(e.getPointerId(idx), e.getX(idx), e.getY(idx))
            }
            MotionEvent.ACTION_MOVE -> {
                for (i in 0 until e.pointerCount) {
                    move(e.getPointerId(i), e.getX(i), e.getY(i))
                }
            }
            MotionEvent.ACTION_POINTER_UP -> end(e.getPointerId(e.actionIndex))
            MotionEvent.ACTION_UP -> {
                end(e.getPointerId(e.actionIndex))
                if (bindings.size() > 0) releaseAllTouches()
            }
            MotionEvent.ACTION_CANCEL -> releaseAllTouches()
        }
        return true
    }

    private fun begin(id: Int, x: Float, y: Float) {
        bindings[id]?.let { end(id) }
        val now = SystemClock.uptimeMillis()

        if (showNumLockChip && numLockChip.contains(x, y)) {
            feedback(strong = true)
            InputController.tapCombo(listOf(Keys.NUM_LOCK))
            bindings.put(id, Binding(-1, x, y, x, y, downAt = now, isNumLockChip = true))
            return
        }

        val zi = hitZone(x, y)
        if (zi < 0) {
            bindings.put(id, Binding(-1, x, y, x, y, downAt = now))
            return
        }
        val z = zones[zi]
        val b = Binding(zi, x, y, x, y, downAt = now)
        bindings.put(id, b)

        when (z.kind) {
            Kind.THROTTLE -> {
                throttleTouched = true
                b.startVal = throttleVal
                feedback()
            }
            Kind.RUDDER -> {
                rudderTouched = true
                updateRudderFromTouch(x)
                feedback()
            }
            Kind.STICK -> {
                stickTouched = true
                if (now - lastStickTapAt < 320L) {
                    lastStickTapAt = 0L
                    stickX = 0f
                    stickY = 0f
                    FlightController.engine.centerControls()
                    FlightController.recenterTilt()
                    feedback(strong = true)
                } else {
                    lastStickTapAt = now
                    updateStickFromTouch(x, y)
                    feedback()
                }
            }
            Kind.CAMERA_PAD -> {
                camTouched = true
                InputController.mouseDown(1)
            }
            Kind.KEY -> {
                z.pressCount++
                if (z.pressCount == 1) InputController.press(z.code)
                feedback()
            }
            Kind.COMBO -> {
                z.pressCount++
                feedback()
            }
            Kind.ZOOM -> {
                z.pressCount++
                InputController.scroll(z.wheelDelta)
                feedback()
            }
            Kind.MENU, Kind.CENTER, Kind.TILT_TOGGLE, Kind.RELEASE_ALL -> {
                z.pressCount++
                feedback()
            }
        }
        invalidate()
    }

    private fun move(id: Int, x: Float, y: Float) {
        val b = bindings[id] ?: return
        if (b.zoneIdx < 0) return
        b.movedDist += kotlin.math.hypot(x - b.lastX, y - b.lastY)
        val z = zones[b.zoneIdx]
        when (z.kind) {
            Kind.THROTTLE -> {
                val trackH = max(z.rect.height() - 54 * dp, 40 * dp)
                val next = (b.startVal + (b.startY - y) / trackH).coerceIn(0f, 1f)
                if (abs(next - throttleVal) > 0.002f) {
                    throttleVal = next
                    FlightController.engine.setThrottle(next)
                    invalidate()
                }
            }
            Kind.RUDDER -> {
                updateRudderFromTouch(x)
                invalidate()
            }
            Kind.STICK -> {
                updateStickFromTouch(x, y)
                invalidate()
            }
            Kind.CAMERA_PAD -> {
                val sens = Settings.msfsCameraSens
                b.camFracX += (x - b.lastX) * sens
                b.camFracY += (y - b.lastY) * sens
                val dx = b.camFracX.toInt()
                val dy = b.camFracY.toInt()
                b.camFracX -= dx
                b.camFracY -= dy
                if (dx != 0 || dy != 0) InputController.mouseMove(dx, dy)
            }
            else -> {}
        }
        b.lastX = x
        b.lastY = y
    }

    private fun end(id: Int) {
        val b = bindings[id] ?: return
        bindings.remove(id)
        if (b.zoneIdx < 0) return
        val z = zones[b.zoneIdx]
        val now = SystemClock.uptimeMillis()

        when (z.kind) {
            Kind.THROTTLE -> throttleTouched = anyBindingFor(Kind.THROTTLE)
            Kind.RUDDER -> {
                rudderTouched = anyBindingFor(Kind.RUDDER)
                if (!rudderTouched) {
                    rudderVal = 0f
                    FlightController.engine.setRudder(0f, active = false)
                }
            }
            Kind.STICK -> {
                stickTouched = anyBindingFor(Kind.STICK)
                if (!stickTouched) {
                    if (FlightController.tiltEnabled) {
                        stickX = FlightController.tiltRoll
                        stickY = FlightController.tiltPitch
                        FlightController.engine.setStick(stickX, stickY, abs(stickX) > 0.04f || abs(stickY) > 0.04f)
                    } else {
                        stickX = 0f
                        stickY = 0f
                        FlightController.engine.setStick(0f, 0f, active = false)
                    }
                }
            }
            Kind.CAMERA_PAD -> {
                camTouched = anyBindingFor(Kind.CAMERA_PAD)
                InputController.mouseUp(1)
                if (b.movedDist < 12 * dp && now - b.downAt < 260L) {
                    if (now - lastCamTapAt < 340L) {
                        lastCamTapAt = 0L
                        InputController.tapCombo(listOf(Keys.LCTRL, Keys.SPACE))
                        feedback(strong = true)
                    } else {
                        lastCamTapAt = now
                    }
                }
            }
            Kind.KEY -> {
                if (z.pressCount > 0) {
                    z.pressCount--
                    if (z.pressCount == 0) InputController.release(z.code)
                }
            }
            Kind.COMBO -> {
                if (z.pressCount > 0) {
                    z.pressCount--
                    if (z.pressCount == 0) InputController.tapCombo(z.combo.toList())
                }
            }
            Kind.ZOOM -> if (z.pressCount > 0) z.pressCount--
            Kind.MENU -> {
                if (z.pressCount > 0) {
                    z.pressCount--
                    if (z.pressCount == 0) {
                        releaseAllTouches()
                        onMenu?.invoke()
                    }
                }
            }
            Kind.CENTER -> {
                if (z.pressCount > 0) {
                    z.pressCount--
                    if (z.pressCount == 0) {
                        stickX = 0f
                        stickY = 0f
                        rudderVal = 0f
                        FlightController.engine.centerControls()
                        FlightController.recenterTilt()
                        feedback(strong = true)
                    }
                }
            }
            Kind.TILT_TOGGLE -> {
                if (z.pressCount > 0) {
                    z.pressCount--
                    if (z.pressCount == 0) {
                        val next = !FlightController.tiltEnabled
                        if (!FlightController.setTilt(next)) {
                            android.widget.Toast.makeText(context, "Датчик наклона недоступен на этом устройстве", android.widget.Toast.LENGTH_SHORT).show()
                        } else if (!next && !stickTouched) {
                            stickX = 0f
                            stickY = 0f
                            FlightController.engine.setStick(0f, 0f, active = false)
                        }
                    }
                }
            }
            Kind.RELEASE_ALL -> {
                if (z.pressCount > 0) {
                    z.pressCount--
                    if (z.pressCount == 0) {
                        releaseAllTouches()
                        InputController.releaseAll()
                    }
                }
            }
        }
        invalidate()
    }

    private fun anyBindingFor(kind: Kind): Boolean {
        for (i in 0 until bindings.size()) {
            val zi = bindings.valueAt(i).zoneIdx
            if (zi >= 0 && zones[zi].kind == kind) return true
        }
        return false
    }

    private fun updateStickFromTouch(x: Float, y: Float) {
        val r = stickZone.rect
        val travel = max(stickTravel(r), 1f)
        val rawX = ((x - r.centerX()) / travel).coerceIn(-1f, 1f)
        val rawY = ((y - r.centerY()) / travel).coerceIn(-1f, 1f)
        // Subtle 8% deadzone so resting thumb near center holds steady neutral.
        stickX = if (abs(rawX) < 0.08f) 0f else rawX
        stickY = if (abs(rawY) < 0.08f) 0f else rawY
        FlightController.engine.setStick(stickX, stickY, active = true)
    }

    private fun updateRudderFromTouch(x: Float) {
        val r = rudderZone.rect
        val half = max((r.width() - 28 * dp) / 2f, 1f)
        val raw = ((x - r.centerX()) / half).coerceIn(-1f, 1f)
        rudderVal = if (abs(raw) < 0.08f) 0f else raw
        FlightController.engine.setRudder(rudderVal, active = true)
    }

    fun releaseAllTouches() {
        for (i in 0 until bindings.size()) {
            val b = bindings.valueAt(i)
            if (b.zoneIdx < 0) continue
            val z = zones[b.zoneIdx]
            when (z.kind) {
                Kind.KEY -> if (z.pressCount > 0) InputController.release(z.code)
                Kind.CAMERA_PAD -> InputController.mouseUp(1)
                else -> {}
            }
        }
        bindings.clear()
        for (z in zones) z.pressCount = 0
        stickTouched = false
        rudderTouched = false
        throttleTouched = false
        camTouched = false
        if (!FlightController.tiltEnabled) {
            stickX = 0f
            stickY = 0f
        }
        rudderVal = 0f
        FlightController.engine.releaseAll()
        invalidate()
    }
}
