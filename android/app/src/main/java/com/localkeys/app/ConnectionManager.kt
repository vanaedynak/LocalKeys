package com.localkeys.app

import android.annotation.SuppressLint
import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import org.json.JSONObject
import java.net.Inet4Address

data class DiscoveredPC(val name: String, val host: String, val port: Int, val source: String)

/**
 * Keeps a USB link and a Wi-Fi link alive at the same time and routes input through the best one:
 * USB when the cable is plugged in (ADB reverse tunnel), otherwise Wi-Fi. Switching is seamless:
 * the held-keys state is re-synced on the new link, and the PC releases whatever a dead link held.
 * Main thread only, except emergencyReleaseAll().
 */
@SuppressLint("StaticFieldLeak")
object ConnectionManager {
    enum class Phase { IDLE, SEARCHING, CONNECTING, PAIRING, DENIED, CONNECTED }

    var phase = Phase.IDLE; private set
    var transport: Link.Kind? = null; private set
    var pcName = ""; private set
    var rttMs: Int? = null; private set
    var pairingCode: String? = null; private set
    var pcState: PcState? = null; private set
    var discovered: List<DiscoveredPC> = emptyList(); private set
    var scanning = false; private set
    var statusDetail = ""; private set
    var pcUnresponsive = false; private set
    var usbLinked = false; private set
    var wifiLinked = false; private set

    /** Status / pairing changed (UI). */
    val onChange = ArrayList<() -> Unit>()
    /** The PC's keyboard layout or lock keys changed (keycap legends). */
    val onLegends = ArrayList<() -> Unit>()

    private lateinit var ctx: Context
    private val main = Handler(Looper.getMainLooper())
    private var usbLink: Link? = null
        set(v) { field = v; publishLinks() }
    private var wifiLink: Link? = null
        set(v) { field = v; publishLinks() }
    @Volatile private var linksSnapshot: List<Link> = emptyList()
    private fun publishLinks() { linksSnapshot = listOfNotNull(usbLink, wifiLink) }

    private var lastActive: Link? = null
    private var running = false
    private var nextWifiAttempt = 0L
    private var nextUsbAttempt = 0L
    private var wifiAttempt = 0
    private var deniedUntil = 0L
    private var lostSince: Long? = null
    private var startedAt = 0L
    private var lastAutoScan = 0L
    private var autoScanEvery = 40_000L
    private var nsdFound: List<DiscoveredPC> = emptyList()
    private var scanFound: List<DiscoveredPC> = emptyList()
    private var scanner: NetworkScanner? = null

    val activeLink: Link?
        get() {
            usbLink?.let { if (it.authed) return it }
            wifiLink?.let { if (it.authed) return it }
            return null
        }

    fun init(context: Context) {
        ctx = context.applicationContext
    }

    private fun now() = Link.now()

    private val ticker = object : Runnable {
        override fun run() {
            tick()
            if (running) main.postDelayed(this, 500)
        }
    }

    // MARK: lifecycle

    fun start() {
        if (running) return
        running = true
        startedAt = now()
        nextWifiAttempt = 0
        nextUsbAttempt = 0
        startDiscovery()
        main.removeCallbacks(ticker)
        main.post(ticker)
    }

    /** App leaves the screen: release everything on the PC and drop the links. */
    fun stop() {
        if (!running) return
        activeLink?.send(Proto.frame(Msg.RELEASE_ALL))
        InputController.resetLocal()
        running = false
        main.removeCallbacks(ticker)
        stopDiscovery()
        scanner?.cancel()
        scanner = null
        scanning = false
        usbLink?.close()
        wifiLink?.close()
        refresh()
    }

    fun send(data: ByteArray) {
        activeLink?.send(data)
    }

    /** Called from the watchdog thread while the main thread is stuck: tell the PC to let go now. */
    fun emergencyReleaseAll() {
        val f = Proto.frame(Msg.RELEASE_ALL)
        for (l in linksSnapshot) l.send(f)
    }

    fun sendCommand(cmd: String, arg: String? = null) {
        activeLink?.send(Proto.command(cmd, arg))
    }

    fun reconnectWifi() {
        wifiLink?.close()
        wifiAttempt = 0
        nextWifiAttempt = 0
        if (running) tick()
    }

    fun reconnectUsb() {
        usbLink?.close()
        nextUsbAttempt = 0
        if (running) tick()
    }

    // MARK: discovery (mDNS / DNS-SD, the same service the iPad finds)

    private var nsd: NsdManager? = null
    private var discovery: NsdManager.DiscoveryListener? = null
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false

    private fun startDiscovery() {
        if (discovery != null) return
        val m = ctx.getSystemService(NsdManager::class.java) ?: return
        nsd = m
        val l = object : NsdManager.DiscoveryListener {
            override fun onServiceFound(si: NsdServiceInfo) {
                main.post { resolveQueue.addLast(si); resolveNext() }
            }
            override fun onServiceLost(si: NsdServiceInfo) {
                main.post {
                    nsdFound = nsdFound.filter { it.name != si.serviceName }
                    mergeDiscovered()
                }
            }
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                main.post {
                    discovery = null
                    if (running) main.postDelayed({ if (running) startDiscovery() }, 5000)
                }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
        }
        discovery = l
        try {
            m.discoverServices(Proto.SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
        } catch (_: Exception) {
            discovery = null
        }
    }

    private fun stopDiscovery() {
        val l = discovery ?: return
        discovery = null
        try { nsd?.stopServiceDiscovery(l) } catch (_: Exception) {}
        resolveQueue.clear()
        resolving = false
    }

    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving || resolveQueue.isEmpty()) return
        val m = nsd ?: return
        val si = resolveQueue.removeFirst()
        resolving = true
        try {
            m.resolveService(si, object : NsdManager.ResolveListener {
                override fun onResolveFailed(info: NsdServiceInfo, errorCode: Int) {
                    main.post { resolving = false; resolveNext() }
                }
                override fun onServiceResolved(info: NsdServiceInfo) {
                    val addrs = if (Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
                    val addr = addrs.firstOrNull { it is Inet4Address } ?: addrs.firstOrNull()
                    main.post {
                        resolving = false
                        if (addr != null) {
                            val pc = DiscoveredPC(info.serviceName, addr.hostAddress ?: "", info.port, "mdns")
                            nsdFound = nsdFound.filter { it.name != pc.name } + pc
                            mergeDiscovered()
                            if (wifiLink == null) nextWifiAttempt = 0
                        }
                        resolveNext()
                    }
                }
            })
        } catch (_: Exception) {
            resolving = false
        }
    }

    private fun mergeDiscovered() {
        val list = nsdFound.sortedBy { it.name }.toMutableList()
        for (s in scanFound) if (list.none { it.name == s.name }) list.add(s)
        discovered = list
        notifyChange()
    }

    fun scanNetwork() {
        if (scanning) return
        scanning = true
        notifyChange()
        val sc = NetworkScanner(ctx)
        scanner = sc
        sc.scan { found ->
            scanning = false
            scanFound = found.map { DiscoveredPC(it.first, it.second, Proto.PORT, "scan") }
            mergeDiscovered()
            if (wifiLink?.authed != true) reconnectWifi()
        }
    }

    /** The Wi-Fi network, so LAN sockets go through it even when mobile data is the default route. */
    fun wifiNetwork(): Network? {
        val cm = ctx.getSystemService(ConnectivityManager::class.java) ?: return null
        @Suppress("DEPRECATION")
        for (n in cm.allNetworks) {
            val c = cm.getNetworkCapabilities(n) ?: continue
            if (c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) return n
        }
        return null
    }

    // MARK: links

    private fun wifiCandidates(): List<Pair<String, Int>> {
        val list = ArrayList<Pair<String, Int>>()
        val manual = Settings.manualHost.trim()
        if (manual.isNotEmpty()) {
            val idx = manual.lastIndexOf(':')
            if (idx > 0 && !manual.contains("::")) {
                val port = manual.substring(idx + 1).toIntOrNull()
                if (port != null) return listOf(manual.substring(0, idx) to port)
            }
            return listOf(manual to Proto.PORT)
        }
        val pref = Settings.preferredPC
        discovered.firstOrNull { pref.isNotEmpty() && it.name == pref }?.let { list.add(it.host to it.port) }
        for (d in discovered) if (pref.isEmpty() || d.name == pref) {
            if (list.none { it.first == d.host }) list.add(d.host to d.port)
        }
        val hosts = Settings.knownHosts.toMutableList()
        val last = Settings.lastHost
        if (last.isNotEmpty() && last !in hosts) hosts.add(0, last)
        for (h in hosts) if (list.none { it.first == h }) list.add(h to Proto.PORT)
        return list
    }

    private fun connectWifi() {
        val c = wifiCandidates()
        if (c.isEmpty()) return
        val (host, port) = c[wifiAttempt % c.size]
        wifiAttempt++
        val name = discovered.firstOrNull { it.host == host }?.name ?: host
        val link = Link(Link.Kind.WIFI, host, port, name, wifiNetwork())
        attach(link)
        wifiLink = link
        link.start()
    }

    private fun connectUsb() {
        val link = Link(Link.Kind.USB, "127.0.0.1", Proto.PORT, "USB")
        attach(link)
        usbLink = link
        link.start()
    }

    private fun attach(link: Link) {
        link.onReady = { l ->
            if (l.kind == Link.Kind.WIFI) l.remoteIp?.let { if (!it.contains(':')) Settings.lastHost = it }
            refresh()
        }
        link.onClose = { l ->
            if (usbLink === l) {
                usbLink = null
                // Nothing listens on the phone's loopback until the PC sets up the ADB tunnel: retry calmly.
                nextUsbAttempt = now() + if (l.serverHelloName != null) 500 else 1500
            }
            if (wifiLink === l) {
                wifiLink = null
                if (l.denied) deniedUntil = now() + 15_000
                val delay = when {
                    l.denied -> 15_000L
                    l.authed || l.serverHelloName != null -> 500L
                    else -> minOf(800L * wifiAttempt, 3000L)
                }
                nextWifiAttempt = now() + delay
            }
            refresh()
        }
        link.onFrame = { l, type, p -> handle(l, type, p) }
    }

    private fun handle(link: Link, type: Int, p: ByteArray) {
        when (type) {
            Msg.PING -> link.send(Proto.frame(Msg.PONG, p))
            Msg.PONG -> Proto.pingTime(p)?.let { t ->
                val ms = (System.nanoTime() - t) / 1_000_000.0
                if (ms >= 0) {
                    link.rttMs = link.rttMs?.let { it * 0.7 + ms * 0.3 } ?: ms
                    if (link === activeLink) setRtt(link.rttMs!!.toInt())
                }
            }
            Msg.SERVER_HELLO -> {
                val o = Proto.parse(p) ?: run { link.close(); return }
                val pcId = o.optString("pcId")
                link.pcId = pcId
                link.serverHelloName = o.optString("pcName")
                val hello = JSONObject()
                    .put("v", Proto.VERSION)
                    .put("deviceId", Settings.deviceId)
                    .put("name", Settings.deviceName)
                Settings.token(pcId)?.let { hello.put("token", it) }
                link.send(Proto.json(Msg.HELLO, hello))
                refresh()
            }
            Msg.HELLO_ACK -> {
                val o = Proto.parse(p) ?: return
                when (o.optString("status")) {
                    "ok" -> {
                        val token = o.optString("token", "")
                        val pcId = link.pcId
                        if (token.isNotEmpty() && pcId != null) Settings.setToken(token, pcId)
                        link.pairingCode = null
                        link.authed = true
                        if (link.kind == Link.Kind.WIFI) wifiAttempt = 0
                    }
                    "pending" -> link.pairingCode = o.optString("code")
                    else -> {
                        link.denied = true
                        link.close()
                    }
                }
                refresh()
            }
            Msg.PC_STATE -> {
                val o = Proto.parse(p) ?: return
                val st = PcState.from(o)
                if (st.addresses.isNotEmpty() && st.addresses != Settings.knownHosts) Settings.knownHosts = st.addresses
                // Only the active link's PC drives the keycap legends.
                if (link === activeLink || activeLink == null) {
                    if (st != pcState) {
                        pcState = st
                        onLegends.forEach { it() }
                        notifyChange()
                    }
                }
            }
        }
    }

    private fun tick() {
        if (!running) return
        val t = now()
        for (l in listOfNotNull(usbLink, wifiLink)) {
            if (!l.ready) continue
            if (t - l.lastRx > 4500) { l.close(); continue }
            l.send(Proto.ping())
        }
        if (Settings.usbEnabled && usbLink == null && t >= nextUsbAttempt) connectUsb()
        // Discovery found nothing and no known address works: probe the subnet now and then.
        if (Settings.wifiEnabled && wifiLink?.authed != true && Settings.manualHost.isBlank() && !scanning &&
            nsdFound.isEmpty() && t - lastAutoScan > autoScanEvery && t - startedAt > 6000) {
            lastAutoScan = t
            // USB already carries input: Wi-Fi is only a standby link, so look much less often.
            autoScanEvery = if (usbLink?.authed == true) 300_000L else minOf(autoScanEvery * 2, 240_000L)
            scanNetwork()
        }
        if (wifiLink?.authed == true || nsdFound.isNotEmpty()) autoScanEvery = 40_000L
        if (Settings.wifiEnabled && wifiLink == null && t >= nextWifiAttempt) {
            connectWifi()
            if (wifiLink == null) nextWifiAttempt = t + 1500
        }
        refresh()
    }

    private fun setRtt(v: Int) {
        val cur = rttMs
        if (cur != null && kotlin.math.abs(cur - v) < 2) return
        rttMs = v
        notifyChange()
    }

    private fun notifyChange() {
        onChange.forEach { it() }
    }

    fun refresh() {
        val active = activeLink
        var changed = false
        if (active !== lastActive) {
            lastActive = active
            changed = true
            if (active != null) {
                // Transport switch (or first connect): make the PC mirror exactly what is held now.
                active.send(InputController.stateSyncFrame())
                pcState?.let { if (active.serverHelloName != it.pcName) pcState = null }
                sendCommand("requestState")
            }
        }
        fun <T> upd(cur: T, v: T, set: (T) -> Unit) { if (cur != v) { set(v); changed = true } }

        upd(usbLinked, usbLink?.authed == true) { usbLinked = it }
        upd(wifiLinked, wifiLink?.authed == true) { wifiLinked = it }
        upd(transport, active?.kind) { transport = it }
        upd(pcName, active?.serverHelloName ?: usbLink?.serverHelloName ?: wifiLink?.serverHelloName ?: "") { pcName = it }
        if (active == null) upd(rttMs, null) { rttMs = it } else active.rttMs?.let { setRtt(it.toInt()) }

        val pairing = listOfNotNull(usbLink, wifiLink).firstOrNull { it.pairingCode != null && !it.authed }
        upd(pairingCode, if (active == null) pairing?.pairingCode else null) { pairingCode = it }

        val t = now()
        val newPhase = when {
            !running -> Phase.IDLE
            active != null -> Phase.CONNECTED
            pairingCode != null -> Phase.PAIRING
            deniedUntil > t -> Phase.DENIED
            usbLink?.ready == true || wifiLink != null -> Phase.CONNECTING
            else -> Phase.SEARCHING
        }
        upd(phase, newPhase) { phase = it }

        if (newPhase == Phase.CONNECTED || newPhase == Phase.IDLE || newPhase == Phase.PAIRING) lostSince = null
        else if (lostSince == null) lostSince = t
        val knownPC = Settings.knownHosts.isNotEmpty() || Settings.lastHost.isNotEmpty()
        upd(pcUnresponsive, knownPC && (lostSince?.let { t - it > 15_000 } ?: false)) { pcUnresponsive = it }

        if (active == null && pcState != null) {
            pcState = null
            onLegends.forEach { it() }
            changed = true
        }

        val detail = when (newPhase) {
            Phase.CONNECTED -> if (active?.kind == Link.Kind.USB) {
                "USB-кабель" + if (wifiLinked) " · Wi-Fi в резерве" else ""
            } else "Wi-Fi"
            Phase.SEARCHING, Phase.CONNECTING -> when {
                pcUnresponsive -> "ПК не отвечает: проверьте, что он включён, в той же сети и LocalKeys запущен в трее"
                newPhase == Phase.CONNECTING -> "Подключение к ${wifiLink?.label ?: "ПК"}…"
                discovered.isEmpty() -> "Поиск ПК с LocalKeys…"
                else -> "Найдено: " + discovered.joinToString(", ") { it.name }
            }
            Phase.PAIRING -> "Подтвердите код на компьютере"
            Phase.DENIED -> "Компьютер отклонил подключение"
            Phase.IDLE -> ""
        }
        upd(statusDetail, detail) { statusDetail = it }
        if (changed) notifyChange()
    }
}
