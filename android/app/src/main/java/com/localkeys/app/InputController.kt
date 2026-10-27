package com.localkeys.app

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Single source of truth for what is held on the phone. Reference-counted so that several touches
 * holding the same key produce exactly one press and one release. Main thread only.
 */
object InputController {
    enum class Latch { ONE_SHOT, LOCKED }

    private val keyCounts = HashMap<Int, Int>()
    private val buttonCounts = HashMap<Int, Int>()
    val latched = HashMap<Int, Latch>()
    private val modTaps = HashMap<Int, Pair<Long, Boolean>>()
    private val consumeUp = HashMap<Int, Int>()

    /** Modifier / latch state changed (keycaps recolor; Shift relabels). */
    val onState = ArrayList<() -> Unit>()
    /** The main thread was frozen with keys held and the PC was told to release: drop all touches. */
    val onStallRecovered = ArrayList<() -> Unit>()

    private fun send(d: ByteArray) = ConnectionManager.send(d)
    private fun notifyState() = onState.forEach { it() }

    val shiftActive: Boolean get() = (keyCounts[Keys.LSHIFT] ?: 0) > 0 || (keyCounts[Keys.RSHIFT] ?: 0) > 0
    fun isHeld(c: Int) = (keyCounts[c] ?: 0) > 0

    // MARK: freeze watchdog

    /**
     * A background thread watches the main thread. If the UI hangs while anything is held, the PC
     * is told to release everything right away, and when the UI comes back every touch is dropped
     * so nothing re-presses by itself. (The PC has its own dead-man switch on top of this.)
     */
    @Volatile private var anyHeld = false
    @Volatile private var lastBeat = SystemClock.uptimeMillis()
    @Volatile private var fired = false
    @Volatile private var beatPending = false
    private var watchdog: Thread? = null
    private val main = Handler(Looper.getMainLooper())
    private const val STALL_MS = 600L

    private fun updateHeld() {
        anyHeld = keyCounts.isNotEmpty() || buttonCounts.isNotEmpty()
    }

    fun startWatchdog() {
        if (watchdog != null) return
        val t = Thread({
            while (true) {
                try { Thread.sleep(100) } catch (_: InterruptedException) { return@Thread }
                val stalled = SystemClock.uptimeMillis() - lastBeat > STALL_MS
                if (stalled && anyHeld && !fired) {
                    fired = true
                    ConnectionManager.emergencyReleaseAll()
                }
                if (!beatPending) {
                    beatPending = true
                    main.post { mainBeat() }
                }
            }
        }, "lk-watchdog")
        t.isDaemon = true
        t.priority = Thread.MAX_PRIORITY
        watchdog = t
        t.start()
    }

    private fun mainBeat() {
        lastBeat = SystemClock.uptimeMillis()
        beatPending = false
        if (fired) {
            fired = false
            Log.w("LocalKeys", "main thread stalled with keys held; released everything")
            onStallRecovered.forEach { it() }
            resetLocal()
        }
    }

    // MARK: raw reference-counted keys

    fun press(c: Int) {
        val n = (keyCounts[c] ?: 0) + 1
        keyCounts[c] = n
        updateHeld()
        if (n == 1) {
            send(Proto.keyDown(c))
            if (Keys.isModifier(c)) notifyState()
        }
    }

    fun release(c: Int) {
        val n = keyCounts[c] ?: return
        if (n <= 1) {
            keyCounts.remove(c)
            updateHeld()
            send(Proto.keyUp(c))
            if (Keys.isModifier(c)) notifyState()
        } else {
            keyCounts[c] = n - 1
        }
    }

    // MARK: key touches (with optional sticky modifiers)

    fun touchDown(c: Int) {
        val isMod = Keys.isModifier(c)
        if (isMod && Settings.stickyModifiers) {
            val state = latched[c]
            if (state != null) {
                consumeUp[c] = (consumeUp[c] ?: 0) + 1
                if (state == Latch.ONE_SHOT) {
                    latched[c] = Latch.LOCKED          // double tap: lock until tapped again
                } else {
                    latched.remove(c)                  // tap on a locked modifier: unlock
                    release(c)
                }
                notifyState()
                return
            }
            modTaps[c] = SystemClock.uptimeMillis() to false
        } else if (!isMod) {
            for (k in modTaps.keys.toList()) modTaps[k] = modTaps[k]!!.first to true
        }
        press(c)
    }

    fun touchUp(c: Int) {
        consumeUp[c]?.let { n ->
            if (n > 0) {
                if (n > 1) consumeUp[c] = n - 1 else consumeUp.remove(c)
                return
            }
        }
        val isMod = Keys.isModifier(c)
        val tap = if (isMod && Settings.stickyModifiers) modTaps.remove(c) else null
        if (tap != null && !tap.second && SystemClock.uptimeMillis() - tap.first < 350 &&
            latched[c] == null && (keyCounts[c] ?: 0) == 1) {
            latched[c] = Latch.ONE_SHOT                // quick tap: applies to the next key
            notifyState()
            return
        }
        modTaps.remove(c)
        release(c)
        if (!isMod) consumeOneShots()
    }

    private fun consumeOneShots() {
        val shots = latched.filterValues { it == Latch.ONE_SHOT }.keys.toList()
        if (shots.isEmpty()) return
        for (k in shots) {
            latched.remove(k)
            release(k)
        }
        notifyState()
    }

    fun text(s: String) {
        if (s.isNotEmpty()) send(Proto.text(s))
    }

    fun tapCombo(codes: List<Int>) {
        codes.forEach { press(it) }
        codes.reversed().forEach { release(it) }
    }

    // MARK: sync

    fun stateSyncFrame(): ByteArray {
        var mask = 0
        for ((b, n) in buttonCounts) if (n > 0 && b < 8) mask = mask or (1 shl b)
        return Proto.stateSync(keyCounts.keys, mask)
    }

    fun releaseAll() {
        clear()
        send(Proto.frame(Msg.RELEASE_ALL))
        notifyState()
    }

    /** Forget local state without talking to the PC (links are going away anyway). */
    fun resetLocal() {
        clear()
        notifyState()
    }

    private fun clear() {
        keyCounts.clear()
        buttonCounts.clear()
        latched.clear()
        modTaps.clear()
        consumeUp.clear()
        updateHeld()
    }
}
