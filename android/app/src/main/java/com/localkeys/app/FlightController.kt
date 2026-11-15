package com.localkeys.app

import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.Display
import android.view.Surface
import android.view.WindowManager
import java.lang.ref.WeakReference
import kotlin.math.abs
import kotlin.math.asin
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/** Output sink for flight controls so the tracking logic can be unit-tested without Android. */
interface FlightSink {
    fun keyDown(code: Int)
    fun keyUp(code: Int)
    fun tap(code: Int)
    fun tapCombo(vararg codes: Int)
    fun sendJoystick(axes: IntArray, buttons: Long, holdMask: Int)
}

/**
 * Translates continuous stick, rudder, and throttle positions into either:
 * - KEYBOARD mode: closed-loop proportional Numpad / F-key control for MSFS 2020 default bindings
 *   (Num 4/6 roll, Num 8/2 pitch, Num 5 center aileron+rudder, Num 0/NumEnter rudder, F1..F4 throttle).
 * - VJOY mode: direct 8-axis / 32-button frames (0x23) for Windows VirtualJoystick.
 */
class FlightEngine(private val sink: FlightSink) {
    enum class Mode { KEYBOARD, VJOY }

    var mode: Mode = Mode.KEYBOARD
        set(v) {
            if (field == v) return
            releaseAll()
            field = v
            if (v == Mode.VJOY) updateVjoyAxes()
        }

    var stickTravelMs: Int = 1200
    var throttleTravelMs: Int = 2600
    var invertY: Boolean = false

    var targetRoll = 0f; private set
    var targetPitch = 0f; private set
    var targetRudder = 0f; private set
    var targetThrottle = 0f; private set

    private var stickActive = false
    private var rudderActive = false

    // Estimated in-sim control surface positions in MSFS keyboard mode.
    var simRoll = 0f; private set
    var simPitch = 0f; private set
    var simRudder = 0f; private set
    var simThrottle = 0f; private set

    private var rollDir = 0
    private var pitchDir = 0
    private var rudderDir = 0
    private var throttleDir = 0
    private var cutSent = true
    private var fullSent = false

    private val axes = IntArray(8)
    private var joyButtons = 0L
    private var vjoyUsed = false
    private var vjoyDirty = false
    private val holdMask = 1 shl 2 // Axis Z (throttle) holds position on disconnect.

    fun setStick(x: Float, y: Float, active: Boolean) {
        stickActive = active
        targetRoll = x.coerceIn(-1f, 1f)
        val py = if (invertY) -y else y
        targetPitch = py.coerceIn(-1f, 1f)
        if (mode == Mode.VJOY) updateVjoyAxes()
    }

    fun setRudder(v: Float, active: Boolean) {
        rudderActive = active
        targetRudder = v.coerceIn(-1f, 1f)
        if (mode == Mode.VJOY) updateVjoyAxes()
    }

    fun setThrottle(v: Float) {
        targetThrottle = v.coerceIn(0f, 1f)
        if (mode == Mode.VJOY) updateVjoyAxes()
    }

    fun centerControls() {
        targetRoll = 0f
        targetPitch = 0f
        targetRudder = 0f
        stickActive = false
        rudderActive = false
        if (mode == Mode.KEYBOARD) {
            setDir(rollDir, 0, Keys.NUM_4, Keys.NUM_6) { rollDir = it }
            setDir(pitchDir, 0, Keys.NUM_8, Keys.NUM_2) { pitchDir = it }
            setDir(rudderDir, 0, Keys.NUM_0, Keys.NUM_ENTER) { rudderDir = it }
            sink.tap(Keys.NUM_5)
            simRoll = 0f
            simRudder = 0f
        } else {
            updateVjoyAxes()
            flushVjoyNow()
        }
    }

    fun step(dtMs: Long) {
        if (dtMs <= 0) return
        if (mode == Mode.VJOY) {
            if (vjoyDirty) flushVjoyNow()
            return
        }

        val stickStep = dtMs.toFloat() / max(300, stickTravelMs)
        val throtStep = dtMs.toFloat() / max(500, throttleTravelMs)

        simRoll = (simRoll + rollDir * stickStep).coerceIn(-1f, 1f)
        simPitch = (simPitch + pitchDir * stickStep).coerceIn(-1f, 1f)
        simRudder = (simRudder + rudderDir * stickStep).coerceIn(-1f, 1f)
        simThrottle = (simThrottle + throttleDir * throtStep).coerceIn(0f, 1f)

        // When both roll and rudder are released to neutral, MSFS Num5 snaps both cleanly to 0.
        if (!stickActive && !rudderActive &&
            abs(targetRoll) < 0.04f && abs(targetRudder) < 0.04f &&
            (abs(simRoll) > 0.03f || abs(simRudder) > 0.03f)
        ) {
            setDir(rollDir, 0, Keys.NUM_4, Keys.NUM_6) { rollDir = it }
            setDir(rudderDir, 0, Keys.NUM_0, Keys.NUM_ENTER) { rudderDir = it }
            sink.tap(Keys.NUM_5)
            simRoll = 0f
            simRudder = 0f
        } else {
            val nr = driveSigned(simRoll, targetRoll, rollDir)
            setDir(rollDir, nr, Keys.NUM_4, Keys.NUM_6) { rollDir = it }

            val ny = driveSigned(simRudder, targetRudder, rudderDir)
            setDir(rudderDir, ny, Keys.NUM_0, Keys.NUM_ENTER) { rudderDir = it }
        }

        // MSFS Num5 does NOT center elevator, so drive pitch smoothly back to target (including 0).
        val np = driveSigned(simPitch, targetPitch, pitchDir)
        setDir(pitchDir, np, Keys.NUM_8, Keys.NUM_2) { pitchDir = it }

        // Throttle: F1 at 0%, F4 at 100%, proportional F2/F3 in between.
        when {
            targetThrottle <= 0.02f -> {
                setDir(throttleDir, 0, Keys.f(2), Keys.f(3)) { throttleDir = it }
                if (!cutSent) {
                    sink.tap(Keys.f(1))
                    cutSent = true
                }
                fullSent = false
                simThrottle = 0f
            }
            targetThrottle >= 0.98f -> {
                setDir(throttleDir, 0, Keys.f(2), Keys.f(3)) { throttleDir = it }
                if (!fullSent) {
                    sink.tap(Keys.f(4))
                    fullSent = true
                }
                cutSent = false
                simThrottle = 1f
            }
            else -> {
                cutSent = false
                fullSent = false
                val err = targetThrottle - simThrottle
                val nt = when {
                    throttleDir > 0 -> if (err <= 0.015f || simThrottle >= 0.995f) 0 else 1
                    throttleDir < 0 -> if (err >= -0.015f || simThrottle <= 0.005f) 0 else -1
                    err > 0.025f && simThrottle < 0.995f -> 1
                    err < -0.025f && simThrottle > 0.005f -> -1
                    else -> 0
                }
                setDir(throttleDir, nt, Keys.f(2), Keys.f(3)) { throttleDir = it }
            }
        }
    }

    private fun driveSigned(sim: Float, target: Float, curDir: Int): Int {
        val err = target - sim
        return when {
            curDir > 0 -> if (err <= 0.018f || sim >= 0.995f) 0 else 1
            curDir < 0 -> if (err >= -0.018f || sim <= -0.995f) 0 else -1
            err > 0.045f && sim < 0.995f -> 1
            err < -0.045f && sim > -0.995f -> -1
            else -> 0
        }
    }

    private inline fun setDir(cur: Int, next: Int, negKey: Int, posKey: Int, assign: (Int) -> Unit) {
        if (cur == next) return
        if (cur < 0) sink.keyUp(negKey)
        else if (cur > 0) sink.keyUp(posKey)
        if (next < 0) sink.keyDown(negKey)
        else if (next > 0) sink.keyDown(posKey)
        assign(next)
    }

    private fun updateVjoyAxes() {
        val nx = (targetRoll * 32767f).roundToInt().coerceIn(-32767, 32767)
        val ny = (targetPitch * 32767f).roundToInt().coerceIn(-32767, 32767)
        val nz = ((targetThrottle * 2f - 1f) * 32767f).roundToInt().coerceIn(-32767, 32767)
        val nrz = (targetRudder * 32767f).roundToInt().coerceIn(-32767, 32767)
        if (axes[0] != nx || axes[1] != ny || axes[2] != nz || axes[5] != nrz) {
            axes[0] = nx
            axes[1] = ny
            axes[2] = nz
            axes[5] = nrz
            vjoyDirty = true
        }
    }

    private fun flushVjoyNow() {
        vjoyDirty = false
        vjoyUsed = true
        sink.sendJoystick(axes.copyOf(), joyButtons, holdMask)
    }

    fun resendVjoyIfUsed() {
        if (mode == Mode.VJOY && vjoyUsed) {
            sink.sendJoystick(axes.copyOf(), joyButtons, holdMask)
        }
    }

    fun releaseAll() {
        setDir(rollDir, 0, Keys.NUM_4, Keys.NUM_6) { rollDir = it }
        setDir(pitchDir, 0, Keys.NUM_8, Keys.NUM_2) { pitchDir = it }
        setDir(rudderDir, 0, Keys.NUM_0, Keys.NUM_ENTER) { rudderDir = it }
        setDir(throttleDir, 0, Keys.f(2), Keys.f(3)) { throttleDir = it }
        targetRoll = 0f
        targetPitch = 0f
        targetRudder = 0f
        stickActive = false
        rudderActive = false
        axes[0] = 0
        axes[1] = 0
        axes[5] = 0
        joyButtons = 0L
        vjoyDirty = false
        if (vjoyUsed) {
            sink.sendJoystick(axes.copyOf(), 0L, holdMask)
        }
    }
}

/** Singleton runtime driver tying FlightEngine + phone gravity tilt sensor to InputController. */
object FlightController : SensorEventListener {
    private val main = Handler(Looper.getMainLooper())
    private var lastTickMs = 0L
    private var running = false

    private val sink = object : FlightSink {
        override fun keyDown(code: Int) = InputController.press(code)
        override fun keyUp(code: Int) = InputController.release(code)
        override fun tap(code: Int) = InputController.tapCombo(listOf(code))
        override fun tapCombo(vararg codes: Int) = InputController.tapCombo(codes.toList())
        override fun sendJoystick(axes: IntArray, buttons: Long, holdMask: Int) =
            InputController.sendJoystick(axes, buttons, holdMask)
    }

    val engine = FlightEngine(sink)

    var tiltEnabled = false; private set
    var tiltRoll = 0f; private set
    var tiltPitch = 0f; private set
    var onTiltUpdate: ((Float, Float) -> Unit)? = null

    private var sensors: SensorManager? = null
    private var sensor: Sensor? = null
    private var appCtx: Context? = null
    private var uiCtxRef: WeakReference<Context>? = null
    private var refX: Float? = null
    private var refY: Float? = null

    fun init(ctx: Context) {
        uiCtxRef = WeakReference(ctx)
        if (appCtx != null) return
        appCtx = ctx.applicationContext
        val sm = appCtx!!.getSystemService(SensorManager::class.java)
        sensors = sm
        sensor = sm?.getDefaultSensor(Sensor.TYPE_GRAVITY) ?: sm?.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    }

    val tiltAvailable: Boolean get() = sensor != null

    fun syncSettings() {
        engine.mode = if (Settings.msfsInputMode == "vjoy") FlightEngine.Mode.VJOY else FlightEngine.Mode.KEYBOARD
        engine.stickTravelMs = Settings.msfsStickTravelMs
        engine.invertY = Settings.msfsInvertY
    }

    private val ticker = object : Runnable {
        override fun run() {
            if (!running) return
            val now = SystemClock.uptimeMillis()
            val dt = (now - lastTickMs).coerceIn(1L, 100L)
            lastTickMs = now
            engine.step(dt)
            main.postDelayed(this, 20L)
        }
    }

    fun startLoop() {
        if (running) return
        syncSettings()
        running = true
        lastTickMs = SystemClock.uptimeMillis()
        main.removeCallbacks(ticker)
        main.postDelayed(ticker, 20L)
    }

    fun stopLoop() {
        running = false
        main.removeCallbacks(ticker)
        stopTilt()
        engine.releaseAll()
    }

    fun setTilt(enabled: Boolean): Boolean {
        if (enabled && sensor == null) return false
        tiltEnabled = enabled
        if (enabled) {
            refX = null
            refY = null
            sensors?.registerListener(this, sensor, SensorManager.SENSOR_DELAY_GAME)
        } else {
            sensors?.unregisterListener(this)
            tiltRoll = 0f
            tiltPitch = 0f
            onTiltUpdate?.invoke(0f, 0f)
        }
        return true
    }

    fun stopTilt() {
        if (tiltEnabled) setTilt(false)
    }

    fun recenterTilt() {
        refX = null
        refY = null
    }

    override fun onAccuracyChanged(s: Sensor?, accuracy: Int) {}

    override fun onSensorChanged(e: SensorEvent) {
        if (!tiltEnabled) return
        val gx = e.values[0]
        val gy = e.values[1]
        val gz = e.values[2]
        val gNorm = kotlin.math.sqrt((gx * gx + gy * gy + gz * gz).toDouble()).toFloat().coerceAtLeast(1f)
        val nx = gx / gNorm
        val ny = gy / gNorm

        val rot = displayRotation()
        val (sx, sy) = when (rot) {
            Surface.ROTATION_90 -> -ny to nx
            Surface.ROTATION_270 -> ny to -nx
            Surface.ROTATION_180 -> -nx to -ny
            else -> nx to ny
        }
        val ax = asin(sx.coerceIn(-1f, 1f))
        val ay = asin(sy.coerceIn(-1f, 1f))
        val rx = refX
        val ry = refY
        if (rx == null || ry == null) {
            refX = ax
            refY = ay
            tiltRoll = 0f
            tiltPitch = 0f
            onTiltUpdate?.invoke(0f, 0f)
            return
        }
        val rangeRad = (max(8f, Settings.msfsTiltRangeDeg) * Math.PI / 180.0).toFloat()
        val dz = 0.08f
        fun shape(delta: Float): Float {
            val v = (delta / rangeRad).coerceIn(-1f, 1f)
            val m = max(0f, abs(v) - dz) / (1f - dz)
            return if (v < 0f) -m else m
        }
        tiltRoll = shape(-(ax - rx))
        tiltPitch = shape(ay - ry)
        onTiltUpdate?.invoke(tiltRoll, tiltPitch)
    }

    @Suppress("DEPRECATION")
    private fun displayRotation(): Int {
        val ui = uiCtxRef?.get()
        if (Build.VERSION.SDK_INT >= 30 && ui != null) {
            try {
                ui.display?.let { return it.rotation }
            } catch (_: UnsupportedOperationException) {
                // Non-visual context; fall back to DisplayManager below.
            }
        }
        val dm = appCtx?.getSystemService(DisplayManager::class.java)
        dm?.getDisplay(Display.DEFAULT_DISPLAY)?.let { return it.rotation }
        return appCtx?.getSystemService(WindowManager::class.java)?.defaultDisplay?.rotation ?: Surface.ROTATION_90
    }
}
