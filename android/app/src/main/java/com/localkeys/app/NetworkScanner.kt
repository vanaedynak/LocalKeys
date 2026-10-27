package com.localkeys.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import java.io.DataInputStream
import java.net.Inet4Address
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Fallback discovery for networks where mDNS is blocked (some routers, guest Wi-Fi): probes the
 * local /24 subnet for the LocalKeys port and reads the PC's hello message (its name).
 */
class NetworkScanner(private val ctx: Context) {
    @Volatile private var cancelled = false
    private val pool = Executors.newFixedThreadPool(48)

    fun cancel() {
        cancelled = true
        pool.shutdownNow()
    }

    /** Result on the main thread: (pc name, ip). */
    fun scan(done: (List<Pair<String, String>>) -> Unit) {
        val main = Handler(Looper.getMainLooper())
        Thread({
            val found = java.util.Collections.synchronizedList(ArrayList<Pair<String, String>>())
            val net = ConnectionManager.wifiNetwork()
            val local = localIPv4()
            if (local != null) {
                val (ip, prefix) = local
                val mask = if (prefix >= 24) (-1 shl (32 - prefix)) else -256
                val base = ip and mask
                val bcast = base or mask.inv()
                var h = base + 1
                while (h < bcast && !cancelled) {
                    val addr = h
                    if (addr != ip) pool.execute { probe(addr, net, found) }
                    h++
                }
            }
            pool.shutdown()
            try { pool.awaitTermination(15, TimeUnit.SECONDS) } catch (_: InterruptedException) {}
            val result = found.toList()
            main.post { if (!cancelled) done(result) }
        }, "lk-scan").apply { isDaemon = true }.start()
    }

    private fun probe(addr: Int, net: android.net.Network?, found: MutableList<Pair<String, String>>) {
        if (cancelled) return
        val host = "${addr ushr 24 and 255}.${addr ushr 16 and 255}.${addr ushr 8 and 255}.${addr and 255}"
        try {
            Socket().use { s ->
                net?.bindSocket(s)
                s.connect(InetSocketAddress(host, Proto.PORT), 700)
                s.soTimeout = 1200
                val input = DataInputStream(s.getInputStream())
                val header = ByteArray(2)
                input.readFully(header)
                val len = ((header[0].toInt() and 0xFF) shl 8) or (header[1].toInt() and 0xFF)
                if (len < 2 || len > 4096) return
                val body = ByteArray(len)
                input.readFully(body)
                if (body[0].toInt() != Msg.SERVER_HELLO) return
                val o = Proto.parse(body.copyOfRange(1, len)) ?: return
                found.add(o.optString("pcName", host) to host)
            }
        } catch (_: Exception) {
        }
    }

    /** IPv4 address (as int) and prefix length of the Wi-Fi interface. */
    private fun localIPv4(): Pair<Int, Int>? {
        val cm = ctx.getSystemService(ConnectivityManager::class.java) ?: return null
        @Suppress("DEPRECATION")
        for (n in cm.allNetworks) {
            val c = cm.getNetworkCapabilities(n) ?: continue
            if (!c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
            val lp = cm.getLinkProperties(n) ?: continue
            for (la in lp.linkAddresses) {
                val a = la.address
                if (a is Inet4Address && !a.isLoopbackAddress && !a.isLinkLocalAddress) {
                    val b = a.address
                    val ip = ((b[0].toInt() and 255) shl 24) or ((b[1].toInt() and 255) shl 16) or
                        ((b[2].toInt() and 255) shl 8) or (b[3].toInt() and 255)
                    return ip to la.prefixLength
                }
            }
        }
        return null
    }
}
