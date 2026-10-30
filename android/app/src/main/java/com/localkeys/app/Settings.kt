package com.localkeys.app

import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import org.json.JSONObject
import java.util.UUID

/** User preferences, persisted in SharedPreferences. */
@SuppressLint("StaticFieldLeak")
object Settings {
    private lateinit var p: SharedPreferences
    private var defaultName = "Android"

    fun init(ctx: Context) {
        p = ctx.getSharedPreferences("localkeys", Context.MODE_PRIVATE)
        defaultName = try {
            android.provider.Settings.Global.getString(ctx.contentResolver, "device_name")
        } catch (_: Exception) {
            null
        } ?: "${Build.MANUFACTURER} ${Build.MODEL}"
    }

    private fun b(k: String, d: Boolean) = p.getBoolean(k, d)
    private fun f(k: String, d: Float) = p.getFloat(k, d)
    private fun s(k: String, d: String) = p.getString(k, d) ?: d
    private fun put(block: SharedPreferences.Editor.() -> Unit) = p.edit().apply(block).apply()

    // Appearance
    var themeId: String get() = s("themeId", "midnight"); set(v) = put { putString("themeId", v) }
    var keyGap: Float get() = f("keyGap", 4f); set(v) = put { putFloat("keyGap", v) }
    var showTopBar: Boolean get() = b("showTopBar", true); set(v) = put { putBoolean("showTopBar", v) }
    /** Keyboard size relative to the screen (0.6...1). */
    var kbScale: Float get() = f("kbScale", 1f); set(v) = put { putFloat("kbScale", v) }
    /** Vertical position of a smaller keyboard: 0 top ... 1 bottom. */
    var vpos: Float get() = f("vpos", 0f); set(v) = put { putFloat("vpos", v) }
    /** Max key height relative to its width (taller keys fill a phone screen). */
    var keyAspect: Float get() = f("keyAspect", 1.6f); set(v) = put { putFloat("keyAspect", v) }

    // Keyboard
    var haptics: Boolean get() = b("haptics", true); set(v) = put { putBoolean("haptics", v) }
    var keySound: Boolean get() = b("keySound", false); set(v) = put { putBoolean("keySound", v) }
    var stickyModifiers: Boolean get() = b("stickyModifiers", false); set(v) = put { putBoolean("stickyModifiers", v) }
    /** auto (from the PC) | en | ru | ua */
    var legendMode: String get() = s("legendMode", "auto"); set(v) = put { putString("legendMode", v) }
    var bilingual: Boolean get() = b("bilingual", true); set(v) = put { putBoolean("bilingual", v) }
    /** Second language printed on keycaps while the PC is in English: ru | ua | none */
    var secondLang: String get() = s("secondLang", "ru"); set(v) = put { putString("secondLang", v) }
    var altScale: Float get() = f("altScale", 0.72f); set(v) = put { putFloat("altScale", v) }
    var altShifted: Boolean get() = b("altShifted", true); set(v) = put { putBoolean("altShifted", v) }

    // Typing assist (see TypingAssist)
    var smartTouch: Boolean get() = b("smartTouch", true); set(v) = put { putBoolean("smartTouch", v) }
    var smartWords: Boolean get() = b("smartWords", true); set(v) = put { putBoolean("smartWords", v) }
    var showTouchDots: Boolean get() = b("showTouchDots", false); set(v) = put { putBoolean("showTouchDots", v) }
    var touchModel: String get() = s("touchModel", ""); set(v) = put { putString("touchModel", v) }

    // Connection
    var wifiEnabled: Boolean get() = b("wifiEnabled", true); set(v) = put { putBoolean("wifiEnabled", v) }
    var usbEnabled: Boolean get() = b("usbEnabled", true); set(v) = put { putBoolean("usbEnabled", v) }
    var manualHost: String get() = s("manualHost", ""); set(v) = put { putString("manualHost", v) }
    var preferredPC: String get() = s("preferredPC", ""); set(v) = put { putString("preferredPC", v) }
    var deviceName: String get() = s("deviceName", defaultName); set(v) = put { putString("deviceName", v) }

    var onboarded: Boolean get() = b("onboarded", false); set(v) = put { putBoolean("onboarded", v) }

    val deviceId: String
        get() {
            p.getString("deviceId", null)?.let { return it }
            val id = UUID.randomUUID().toString().uppercase()
            put { putString("deviceId", id) }
            return id
        }

    /** LAN addresses the PC reported (also learned over USB): fallback when discovery fails. */
    var knownHosts: List<String>
        get() = s("knownHosts", "").split(',').filter { it.isNotBlank() }
        set(v) = put { putString("knownHosts", v.joinToString(",")) }
    var lastHost: String get() = s("lastHost", ""); set(v) = put { putString("lastHost", v) }

    private fun tokens(): JSONObject = try { JSONObject(s("tokens", "{}")) } catch (_: Exception) { JSONObject() }
    fun token(pcId: String): String? = tokens().optString(pcId, "").ifEmpty { null }
    fun setToken(token: String?, pcId: String) {
        val t = tokens()
        if (token == null) t.remove(pcId) else t.put(pcId, token)
        put { putString("tokens", t.toString()) }
    }
    fun forgetAllPairings() = put { remove("tokens") }
}
