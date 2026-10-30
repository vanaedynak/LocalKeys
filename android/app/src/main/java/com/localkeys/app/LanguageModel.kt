package com.localkeys.app

import android.content.Context
import java.io.BufferedReader
import java.io.InputStreamReader

/**
 * How likely each letter is to come next, for one language. Built from a frequency word list
 * (assets/lm_<lang>.txt, see tools/lm/build_lm.py): the words that start with what has been typed
 * of the current word say which letters can follow, and letter trigrams over the same words cover
 * words the list doesn't know. Immutable after loading; queries are main-thread only (cache).
 */
class LanguageModel private constructor(
    val alphabet: String,
    /** All words back to back, as letter indices; word i is letters[starts[i] until starts[i + 1]]. */
    private val letters: ByteArray,
    private val starts: IntArray,
    private val counts: FloatArray,
) {
    val size = alphabet.length
    private val k = size + 1                 // + word boundary
    private val edge = size
    private val tri = FloatArray(k * k * k)
    private val bi = FloatArray(k * k)
    private val uni = FloatArray(k)
    private val cache = HashMap<Int, FloatArray>()

    init {
        // Letter trigrams weighted by word frequency, with the boundary on both sides of a word.
        for (i in counts.indices) {
            val n = counts[i]
            var a = edge
            var b = edge
            for (j in starts[i]..starts[i + 1]) {
                val c = if (j < starts[i + 1]) letters[j].toInt() else edge
                tri[(a * k + b) * k + c] += n
                bi[b * k + c] += n
                uni[c] += n
                a = b
                b = c
            }
        }
    }

    fun index(ch: Char): Int = alphabet.indexOf(ch)

    private fun compare(w: Int, prefix: ByteArray, len: Int): Int {
        val s = starts[w]
        val wl = starts[w + 1] - s
        for (j in 0 until len) {
            if (j >= wl) return -1
            val d = letters[s + j] - prefix[j]
            if (d != 0) return d
        }
        return 0
    }

    /** First word that is not before the prefix (`after`: first word past all words with it). */
    private fun bound(prefix: ByteArray, len: Int, after: Boolean): Int {
        var lo = 0
        var hi = counts.size
        while (lo < hi) {
            val mid = (lo + hi) ushr 1
            val c = compare(mid, prefix, len)
            if (c < 0 || (after && c == 0)) lo = mid + 1 else hi = mid
        }
        return lo
    }

    /**
     * Probabilities of each letter (by alphabet index) right after `prefix` (the letters typed of
     * the current word; empty at a word start). The returned array is shared: don't modify it.
     */
    fun next(prefix: ByteArray, len: Int): FloatArray {
        // Short prefixes span thousands of words: remember them. Longer ones are a short scan.
        var key = -1
        if (len <= 2) {
            key = len
            for (j in 0 until len) key = key * 64 + prefix[j] + 1
            cache[key]?.let { return it }
        }
        val out = FloatArray(size)
        val lo = bound(prefix, len, false)
        val hi = bound(prefix, len, true)
        var cont = 0f
        var ended = 0f
        var words = 0
        for (w in lo until hi) {
            val s = starts[w]
            if (starts[w + 1] - s > len) {
                out[letters[s + len].toInt()] += counts[w]
                cont += counts[w]
                words++
            } else {
                ended += counts[w]
            }
        }
        // Trust the dictionary by how many words back it up and how likely the word goes on at all
        // (a finished word followed by more letters is one the list doesn't know).
        val alpha = if (cont > 0f) words / (words + 3f) * (cont / (cont + ended)) else 0f
        val a = if (len >= 2) prefix[len - 2].toInt() else edge
        val b = if (len >= 1) prefix[len - 1].toInt() else edge
        val row3 = (a * k + b) * k
        val row2 = b * k
        var t3 = 0f
        var t2 = 0f
        var t1 = 0f
        for (c in 0 until size) { t3 += tri[row3 + c]; t2 += bi[row2 + c]; t1 += uni[c] }
        var total = 0f
        for (c in 0 until size) {
            var p = 0f
            var wsum = 0f
            if (t3 > 0f) { p += 0.7f * tri[row3 + c] / t3; wsum += 0.7f }
            if (t2 > 0f) { p += 0.2f * bi[row2 + c] / t2; wsum += 0.2f }
            if (t1 > 0f) { p += 0.1f * uni[c] / t1; wsum += 0.1f }
            if (wsum > 0f) p /= wsum
            if (cont > 0f) p = alpha * out[c] / cont + (1 - alpha) * p
            out[c] = p
            total += p
        }
        if (total > 0f) for (c in 0 until size) out[c] /= total
        if (key >= 0) cache[key] = out
        return out
    }

    companion object {
        /** Reads assets/lm_<lang>.txt (alphabet line, then "word count" in alphabet order). */
        fun load(ctx: Context, lang: String): LanguageModel? = try {
            ctx.assets.open("lm_$lang.txt").use { stream ->
                val r = BufferedReader(InputStreamReader(stream, Charsets.UTF_8), 1 shl 16)
                val alphabet = r.readLine() ?: return null
                val idx = IntArray(0x500) { -1 }
                alphabet.forEachIndexed { i, c -> idx[c.code] = i }
                var letters = ByteArray(1 shl 18)
                val starts = ArrayList<Int>(32768)
                val counts = ArrayList<Float>(32768)
                var pos = 0
                while (true) {
                    val line = r.readLine() ?: break
                    val sp = line.lastIndexOf(' ')
                    if (sp <= 0) continue
                    if (pos + sp > letters.size) letters = letters.copyOf(letters.size * 2)
                    val begin = pos
                    var ok = true
                    for (j in 0 until sp) {
                        val code = line[j].code
                        val li = if (code < idx.size) idx[code] else -1
                        if (li < 0) { ok = false; break }
                        letters[pos++] = li.toByte()
                    }
                    if (!ok) { pos = begin; continue }
                    starts.add(begin)
                    counts.add(line.substring(sp + 1).toFloatOrNull() ?: 1f)
                }
                starts.add(pos)
                LanguageModel(alphabet, letters.copyOf(pos), starts.toIntArray(), counts.toFloatArray())
            }
        } catch (_: Exception) {
            null
        }
    }
}
