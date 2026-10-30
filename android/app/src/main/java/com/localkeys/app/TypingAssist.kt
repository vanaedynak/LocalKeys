package com.localkeys.app

import android.content.Context
import android.os.SystemClock
import java.util.concurrent.Executors
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min

/**
 * Fewer missed keys, without autocorrect. The phone can't see or change the text on the PC, so it
 * only decides which key a touch means, at the moment of the touch:
 *
 * - **Your touch.** Every finger misses the same way (thumbs land low and to the side). Each key
 *   learns where you actually hit it, and a backspace followed by a neighbouring key teaches that
 *   the first touch belonged to the second key. The key's touch zone shifts towards your hits.
 * - **Words.** Between two letters, the one that continues the word (RU / UA / EN word lists)
 *   wins a touch on their border. The border moves by at most ~1/5 of a key, so a touch near a
 *   key's centre always types that key, and only in plain typing: never with Ctrl / Alt / Win,
 *   Fn, a key held down (games) or after arrows, mouse-like keys or a pause.
 *
 * Main thread only, except word lists loading in the background.
 */
object TypingAssist {
    // MARK: tunables
    /** Border shift per nat of word likelihood ratio, in keys. Max ~0.2 key at a 500x ratio. */
    private const val WORD_WEIGHT = 0.065f
    private const val MIN_P = 0.002f
    /** How far a learned zone may move from the printed key, in keys. */
    private const val MAX_OFFSET = 0.25f
    /** Samples after which a key's own data outweighs its thumb's average. */
    private const val PRIOR_WEIGHT = 12f
    private const val MAX_SAMPLES = 80f
    private const val CONTEXT_TTL_MS = 8000L
    private const val VERIFY_MS = 1500L

    private lateinit var app: Context
    private val loader = Executors.newSingleThreadExecutor { r -> Thread(r, "lk-words").apply { isDaemon = true; priority = Thread.MIN_PRIORITY } }
    private val models = HashMap<String, LanguageModel?>()
    @Volatile private var loaded: Pair<String, LanguageModel?>? = null
    private val main = android.os.Handler(android.os.Looper.getMainLooper())

    fun init(ctx: Context, keyCount: Int) {
        app = ctx.applicationContext
        offsets = FloatArray(keyCount * 3)
        restore(Settings.touchModel)
    }

    // MARK: language & context

    private var lang: String? = null
    private var model: LanguageModel? = null
    /** Scan code -> letter index in the current model's alphabet. */
    private val letterOf = HashMap<Int, Int>()
    private val prefix = ByteArray(32)
    private var prefixLen = 0
    private var inWord = false               // false: unknown position in the text
    private var lastKeyAt = 0L
    private var probs: FloatArray? = null

    /** What the PC types for each key now (not what the keycaps show: their language can be forced). */
    fun typedTable(pc: PcState?): LegendTable = when {
        pc != null && pc.legends.isNotEmpty() -> pc.legends
        pc?.lang != null -> Legends.table(pc.lang)
        else -> Legends.resolve(null).primary
    }

    /** The PC's keyboard layout changed: pick the word list for its letters. */
    fun setLayout(primary: LegendTable) {
        val chars = HashMap<Int, Char>()
        for ((code, pair) in primary) {
            val c = pair.first.firstOrNull()?.lowercaseChar() ?: continue
            if (Character.isLetter(c)) chars[code] = c
        }
        val all = chars.values.toSet()
        val l = when {
            'ы' in all -> "ru"
            'ї' in all || 'є' in all || 'і' in all -> "uk"
            'q' in all && 'w' in all -> "en"
            else -> null
        }
        letterOf.clear()
        if (l != lang) reset()
        lang = l
        model = null
        if (l == null) return
        val m = modelFor(l) ?: return
        model = m
        for ((code, c) in chars) {
            val i = m.index(c)
            if (i >= 0) letterOf[code] = i
        }
        probs = null
    }

    private fun modelFor(l: String): LanguageModel? {
        if (models.containsKey(l)) return models[l]
        loaded?.let { (name, m) -> if (name == l) { models[l] = m; return m } }
        loader.execute {
            val m = LanguageModel.load(app, l)
            loaded = l to m
            main.post { if (lang == l) setLayout(typedTable(ConnectionManager.pcState)) }
        }
        return null
    }

    fun reset() {
        inWord = false
        prefixLen = 0
        probs = null
    }

    fun isLetter(code: Int) = letterOf.containsKey(code)

    /** Word likelihood of a letter key right now, or null when words must not decide. */
    private fun wordProb(code: Int, now: Long): Float? {
        if (!Settings.smartWords || !inWord || now - lastKeyAt > CONTEXT_TTL_MS) return null
        val m = model ?: return null
        val i = letterOf[code] ?: return null
        val p = probs ?: m.next(prefix, prefixLen).also { probs = it }
        return max(p[i], MIN_P)
    }

    /** A key was pressed (after the touch was resolved). `plain`: no Ctrl / Alt / Win involved. */
    fun onKey(code: Int, plain: Boolean) {
        lastKeyAt = SystemClock.uptimeMillis()
        val li = letterOf[code]
        when {
            code == Keys.LSHIFT || code == Keys.RSHIFT || code == Keys.CAPS -> return
            !plain || Keys.isModifier(code) -> reset()
            li != null -> {
                if (!inWord) { inWord = true; prefixLen = 0 }
                if (prefixLen < prefix.size) prefix[prefixLen++] = li.toByte() else reset()
            }
            code == Keys.BACKSPACE -> if (inWord && prefixLen > 0) prefixLen-- else reset()
            code == Keys.SPACE || code == Keys.ENTER || code == Keys.TAB || code in Keys.printable -> {
                inWord = true
                prefixLen = 0
            }
            else -> reset()
        }
        probs = null
    }

    // MARK: touch zones

    /** Per key: learned centre offset x, y (in keys) and sample count. */
    private var offsets = FloatArray(0)
    /** Per thumb (left / right half): average offset and samples, the prior for little-used keys. */
    private val thumb = FloatArray(6)
    private var dirty = 0

    fun offsetX(i: Int, right: Boolean) = offset(i, 0, right)
    fun offsetY(i: Int, right: Boolean) = offset(i, 1, right)

    private fun offset(i: Int, axis: Int, right: Boolean): Float {
        if (!Settings.smartTouch || i * 3 + 2 >= offsets.size) return 0f
        val t = if (right) 3 else 0
        val tn = thumb[t + 2]
        val prior = thumb[t + axis] * tn / (tn + 20f)
        val n = offsets[i * 3 + 2]
        val v = (n * offsets[i * 3 + axis] + PRIOR_WEIGHT * prior) / (n + PRIOR_WEIGHT)
        return v.coerceIn(-MAX_OFFSET, MAX_OFFSET)
    }

    private fun learn(i: Int, nx: Float, ny: Float, learnX: Boolean, right: Boolean, limit: Float) {
        if (i * 3 + 2 >= offsets.size) return
        val x = nx.coerceIn(-limit, limit)
        val y = ny.coerceIn(-limit, limit)
        val n = min(offsets[i * 3 + 2] + 1, MAX_SAMPLES)
        offsets[i * 3 + 2] = n
        if (learnX) offsets[i * 3] += (x - offsets[i * 3]) / n
        offsets[i * 3 + 1] += (y - offsets[i * 3 + 1]) / n
        if (learnX) {
            val t = if (right) 3 else 0
            val tn = min(thumb[t + 2] + 1, 400f)
            thumb[t + 2] = tn
            thumb[t] += (x - thumb[t]) / tn
            thumb[t + 1] += (y - thumb[t + 1]) / tn
        }
        if (++dirty >= 40) save()
    }

    // MARK: choosing the key

    /** What the keyboard knows about one key for scoring (filled by the view, reused). */
    class Candidate {
        var index = 0
        var code = -1                        // scan code of a plain key, -1 otherwise
        var score = 0f                       // signed distance to the (shifted) key edge, in keys
    }

    /**
     * Picks among the candidates (sorted by nothing in particular): the best geometric score,
     * unless a letter that continues the word is close enough. Returns the position in `c`.
     */
    fun choose(c: Array<Candidate>, n: Int, words: Boolean, now: Long): Int {
        var best = 0
        for (j in 1 until n) if (c[j].score > c[best].score) best = j
        lastOverride = false
        if (!words || !isLetter(c[best].code)) return best
        val pBest = wordProb(c[best].code, now) ?: return best
        var pick = best
        var pickTotal = c[best].score + WORD_WEIGHT * wordGain * ln(pBest)
        for (j in 0 until n) {
            if (j == best || !isLetter(c[j].code)) continue
            val p = wordProb(c[j].code, now) ?: continue
            val total = c[j].score + WORD_WEIGHT * wordGain * ln(p)
            if (total > pickTotal) { pick = j; pickTotal = total }
        }
        lastOverride = pick != best
        return pick
    }

    var lastOverride = false
        private set

    // MARK: verification (did the user keep that key?)

    class Tap(val key: Int, val nx: Float, val ny: Float, val x: Float, val y: Float,
              val learnX: Boolean, val right: Boolean, val override: Boolean, val at: Long)

    private val pending = ArrayDeque<Tap>()
    private var erased: Tap? = null
    /** Adapts how strongly words decide, from whether their choices get erased. */
    private var wordGain = 1f

    /**
     * A key was typed by a touch at (nx, ny) from its centre, in keys; (x, y) in pixels. Kept for a
     * moment: if it is erased right away it was a miss and must not teach the zone.
     */
    fun onTap(key: Int, nx: Float, ny: Float, x: Float, y: Float, learnX: Boolean, right: Boolean, now: Long) {
        commitOld(now)
        pending.addLast(Tap(key, nx, ny, x, y, learnX, right, lastOverride, now))
        if (pending.size > 3) commit(pending.removeFirst())
    }

    /** A key was held down rather than tapped: forget its touch and the word position. */
    fun onHold(key: Int) {
        val i = pending.indexOfLast { it.key == key }
        if (i >= 0) pending.removeAt(i)
        reset()
    }

    /** Backspace: the last typed key was probably wrong. */
    fun onErase(now: Long) {
        commitOld(now)
        val t = pending.removeLastOrNull() ?: return
        erased = t
        if (t.override) wordGain = max(0.4f, wordGain - 0.08f)
    }

    /** The touch erased just before (if recent), once: the next key may be what it meant. */
    fun takeErased(now: Long): Tap? {
        val t = erased ?: return null
        erased = null
        return if (now - t.at < 3000) t else null
    }

    /**
     * After an erase, a neighbouring key typed instead shows where the user meant to touch: the
     * erased touch, at (nx, ny) from the new key's centre, belongs to the new key.
     */
    fun learnCorrection(key: Int, nx: Float, ny: Float, learnX: Boolean, right: Boolean) {
        if (Settings.smartTouch) learn(key, nx, ny, learnX, right, 0.75f)
    }

    private fun commitOld(now: Long) {
        while (pending.isNotEmpty() && now - pending.first().at > VERIFY_MS) commit(pending.removeFirst())
    }

    private fun commit(t: Tap) {
        if (t.override) { wordGain = min(1.5f, wordGain + 0.01f); return }
        if (Settings.smartTouch) learn(t.key, t.nx, t.ny, t.learnX, t.right, 0.6f)
    }

    // MARK: persistence

    fun save() {
        dirty = 0
        if (offsets.isEmpty()) return
        val sb = StringBuilder("v1;")
        sb.append(wordGain).append(';')
        for (v in thumb) sb.append(v).append(',')
        sb.append(';')
        for (v in offsets) sb.append(if (v == 0f) "0" else String.format(java.util.Locale.ROOT, "%.4f", v)).append(',')
        Settings.touchModel = sb.toString()
    }

    private fun restore(s: String) {
        val parts = s.split(';')
        if (parts.size < 4 || parts[0] != "v1") return
        wordGain = parts[1].toFloatOrNull()?.coerceIn(0.4f, 1.5f) ?: 1f
        parts[2].split(',').forEachIndexed { i, v -> if (i < thumb.size) thumb[i] = v.toFloatOrNull() ?: 0f }
        val o = parts[3].split(',')
        if (o.size - 1 != offsets.size) return          // another layout version: start over
        for (i in offsets.indices) offsets[i] = o[i].toFloatOrNull() ?: 0f
    }

    fun forget() {
        offsets.fill(0f)
        thumb.fill(0f)
        wordGain = 1f
        pending.clear()
        erased = null
        save()
    }

    /** For the optional dots on the keys: has this key learned anything yet. */
    fun samples(i: Int): Float = if (i * 3 + 2 < offsets.size) offsets[i * 3 + 2] else 0f

}
