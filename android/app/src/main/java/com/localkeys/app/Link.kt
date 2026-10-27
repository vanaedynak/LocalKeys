package com.localkeys.app

import android.net.Network
import android.os.Handler
import android.os.Looper
import java.io.DataInputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue

/**
 * One framed TCP connection to the PC: over Wi-Fi, or over the USB cable through an ADB reverse
 * tunnel (127.0.0.1 on the phone is the PC's port).
 *
 * Reading and writing run on their own threads, so a busy UI thread never delays a key, and the
 * freeze watchdog can still send from its own thread. Events are delivered on the main thread.
 */
class Link(val kind: Kind, val host: String, val port: Int, val label: String, private val network: Network? = null) {
    enum class Kind { WIFI, USB }

    var onReady: ((Link) -> Unit)? = null
    var onFrame: ((Link, Int, ByteArray) -> Unit)? = null
    var onClose: ((Link) -> Unit)? = null

    @Volatile var closed = false
        private set
    @Volatile private var connected = false
    val ready: Boolean get() = connected && !closed

    // Main-thread state.
    var lastRx = 0L
    var serverHelloName: String? = null
    var pcId: String? = null
    var authed = false
    var pairingCode: String? = null
    var denied = false
    var rttMs: Double? = null
    /** Address actually connected to (Wi-Fi), remembered as a fallback for the next start. */
    var remoteIp: String? = null

    private val main = Handler(Looper.getMainLooper())
    private val socket = Socket()
    private val out = LinkedBlockingQueue<ByteArray>()

    fun start() {
        Thread({ run() }, "lk-link-$label").apply { priority = Thread.MAX_PRIORITY; isDaemon = true }.start()
    }

    private fun run() {
        try {
            network?.bindSocket(socket)
            socket.tcpNoDelay = true
            socket.keepAlive = true
            // DSCP EF (expedited forwarding): Wi-Fi voice queue, the lowest-latency class.
            try { socket.trafficClass = 0xB8 } catch (_: Exception) {}
            socket.connect(InetSocketAddress(host, port), if (kind == Kind.USB) 1500 else 4000)
            if (closed) return
            remoteIp = socket.inetAddress?.hostAddress
            connected = true
            main.post {
                if (!closed) {
                    lastRx = now()
                    onReady?.invoke(this)
                }
            }
            Thread({ writeLoop() }, "lk-send-$label").apply { priority = Thread.MAX_PRIORITY; isDaemon = true }.start()
            val input = DataInputStream(socket.getInputStream())
            val header = ByteArray(2)
            while (!closed) {
                input.readFully(header)
                val len = ((header[0].toInt() and 0xFF) shl 8) or (header[1].toInt() and 0xFF)
                if (len == 0) break
                val body = ByteArray(len)
                input.readFully(body)
                val type = body[0].toInt() and 0xFF
                val payload = body.copyOfRange(1, len)
                main.post {
                    if (!closed) {
                        lastRx = now()
                        onFrame?.invoke(this, type, payload)
                    }
                }
            }
        } catch (_: Exception) {
            // refused / reset / closed: normal
        }
        close()
    }

    private fun writeLoop() {
        try {
            val os = socket.getOutputStream()
            while (!closed) {
                val first = out.take()
                if (closed || first.isEmpty()) break
                // Coalesce whatever queued up meanwhile into one write (one TCP segment).
                if (out.isEmpty()) {
                    os.write(first)
                } else {
                    val batch = ArrayList<ByteArray>()
                    batch.add(first)
                    out.drainTo(batch)
                    val total = batch.sumOf { it.size }
                    val buf = ByteArray(total)
                    var off = 0
                    for (b in batch) { System.arraycopy(b, 0, buf, off, b.size); off += b.size }
                    os.write(buf)
                }
                os.flush()
            }
        } catch (_: Exception) {
        }
        close()
    }

    /** Thread-safe. */
    fun send(data: ByteArray) {
        if (ready) out.offer(data)
    }

    /** Thread-safe; onClose is always delivered on the main thread. */
    fun close() {
        synchronized(this) {
            if (closed) return
            closed = true
        }
        out.offer(ByteArray(0))
        try { socket.close() } catch (_: Exception) {}
        val finish = Runnable {
            authed = false
            onClose?.invoke(this)
        }
        if (Looper.myLooper() == Looper.getMainLooper()) finish.run() else main.post(finish)
    }

    companion object {
        fun now() = System.nanoTime() / 1_000_000
    }
}
