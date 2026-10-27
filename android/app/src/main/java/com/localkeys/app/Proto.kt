package com.localkeys.app

import org.json.JSONArray
import org.json.JSONObject

/**
 * Wire format: [u16 BE length of (type + payload)] [u8 type] [payload].
 * Must stay in sync with windows/LocalKeys/Protocol.cs and ios/LocalKeys/Net/Protocol.swift.
 */
object Msg {
    const val SERVER_HELLO = 0x00
    const val HELLO = 0x01
    const val HELLO_ACK = 0x02
    const val PING = 0x03
    const val PONG = 0x04
    const val KEY_DOWN = 0x10
    const val KEY_UP = 0x11
    const val STATE_SYNC = 0x12
    const val RELEASE_ALL = 0x13
    const val TEXT = 0x14
    const val MOUSE_MOVE = 0x20
    const val MOUSE_BUTTON = 0x21
    const val SCROLL = 0x22
    const val COMMAND = 0x30
    const val PC_STATE = 0x40
}

object Proto {
    const val VERSION = 1
    const val PORT = 47810
    const val SERVICE_TYPE = "_localkeys._tcp"

    fun frame(type: Int, payload: ByteArray = ByteArray(0)): ByteArray {
        val len = payload.size + 1
        val f = ByteArray(payload.size + 3)
        f[0] = (len shr 8).toByte()
        f[1] = len.toByte()
        f[2] = type.toByte()
        System.arraycopy(payload, 0, f, 3, payload.size)
        return f
    }

    private fun u16(v: Int) = byteArrayOf((v shr 8).toByte(), v.toByte())
    private fun i16(v: Int) = u16(v.coerceIn(-32768, 32767) and 0xFFFF)

    fun keyDown(c: Int) = frame(Msg.KEY_DOWN, u16(c))
    fun keyUp(c: Int) = frame(Msg.KEY_UP, u16(c))
    fun mouseButton(b: Int, down: Boolean) = frame(Msg.MOUSE_BUTTON, byteArrayOf(b.toByte(), if (down) 1 else 0))
    fun scroll(v: Int, h: Int) = frame(Msg.SCROLL, i16(v) + i16(h))
    fun text(s: String): ByteArray {
        val b = s.toByteArray(Charsets.UTF_8)
        return frame(Msg.TEXT, if (b.size > 60000) b.copyOf(60000) else b)
    }

    fun stateSync(keys: Collection<Int>, buttons: Int): ByteArray {
        val list = keys.take(255)
        val p = ByteArray(2 + list.size * 2)
        p[0] = list.size.toByte()
        list.forEachIndexed { i, k ->
            p[1 + i * 2] = (k shr 8).toByte()
            p[2 + i * 2] = k.toByte()
        }
        p[p.size - 1] = buttons.toByte()
        return frame(Msg.STATE_SYNC, p)
    }

    /** Opaque 8 bytes echoed back by the PC: our monotonic clock, for the round-trip time. */
    fun ping(): ByteArray {
        var t = System.nanoTime()
        val p = ByteArray(8)
        for (i in 0 until 8) { p[i] = t.toByte(); t = t shr 8 }
        return frame(Msg.PING, p)
    }

    fun pingTime(p: ByteArray): Long? {
        if (p.size != 8) return null
        var t = 0L
        for (i in 7 downTo 0) t = (t shl 8) or (p[i].toLong() and 0xFF)
        return t
    }

    fun json(type: Int, o: JSONObject) = frame(type, o.toString().toByteArray(Charsets.UTF_8))

    fun command(cmd: String, arg: String? = null): ByteArray {
        val o = JSONObject().put("cmd", cmd)
        if (arg != null) o.put("arg", arg)
        return json(Msg.COMMAND, o)
    }

    fun parse(p: ByteArray): JSONObject? = try {
        JSONObject(String(p, Charsets.UTF_8))
    } catch (_: Exception) {
        null
    }
}

data class KbLayoutInfo(val id: String, val name: String, val lang: String)

data class PcState(
    val pcName: String,
    val layoutId: String?,
    val lang: String?,
    val layoutName: String?,
    val layouts: List<KbLayoutInfo>,
    /** scan code -> (normal, shifted) of the PC's active layout */
    val legends: Map<Int, Pair<String, String>>,
    val caps: Boolean,
    val num: Boolean,
    val scroll: Boolean,
    val addresses: List<String>,
) {
    companion object {
        fun from(o: JSONObject): PcState {
            val layouts = ArrayList<KbLayoutInfo>()
            o.optJSONArray("layouts")?.let { a ->
                for (i in 0 until a.length()) {
                    val l = a.optJSONObject(i) ?: continue
                    layouts.add(KbLayoutInfo(l.optString("id"), l.optString("name"), l.optString("lang")))
                }
            }
            val legends = HashMap<Int, Pair<String, String>>()
            o.optJSONObject("legends")?.let { m ->
                for (k in m.keys()) {
                    val code = k.toIntOrNull() ?: continue
                    val v: JSONArray = m.optJSONArray(k) ?: continue
                    if (v.length() >= 2) legends[code] = v.optString(0) to v.optString(1)
                }
            }
            val addrs = ArrayList<String>()
            o.optJSONArray("addresses")?.let { a -> for (i in 0 until a.length()) addrs.add(a.optString(i)) }
            fun str(k: String) = if (o.has(k) && !o.isNull(k)) o.optString(k) else null
            return PcState(
                pcName = o.optString("pcName"),
                layoutId = str("layoutId"),
                lang = str("lang"),
                layoutName = str("layoutName"),
                layouts = layouts,
                legends = legends,
                caps = o.optBoolean("caps"),
                num = o.optBoolean("num"),
                scroll = o.optBoolean("scroll"),
                addresses = addrs,
            )
        }
    }
}
