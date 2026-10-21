import Foundation
import QuartzCore

/// Single source of truth for what is held on the iPad side. Reference-counted so that
/// several touches/elements holding the same key produce exactly one press and one release.
final class InputController {
    static let shared = InputController()

    enum Latch { case oneShot, locked }

    private(set) var keyCounts: [UInt16: Int] = [:] { didSet { updateHeldFlag() } }
    private(set) var buttonCounts: [UInt8: Int] = [:] { didSet { updateHeldFlag() } }
    private(set) var latched: [UInt16: Latch] = [:]

    private var modTaps: [UInt16: (time: CFTimeInterval, interrupted: Bool)] = [:]
    private var consumeUp: [UInt16: Int] = [:]
    private var remX: Double = 0, remY: Double = 0
    private var remSV: Double = 0, remSH: Double = 0

    private let connection = ConnectionManager.shared
    private var settings: AppSettings { AppSettings.shared }

    private func send(_ data: Data) { connection.send(data) }

    var shiftActive: Bool { (keyCounts[KC.lshift] ?? 0) > 0 || (keyCounts[KC.rshift] ?? 0) > 0 }
    func isHeld(_ code: UInt16) -> Bool { (keyCounts[code] ?? 0) > 0 }

    private func notify() {
        NotificationCenter.default.post(name: .lkInputStateChanged, object: nil)
    }

    // MARK: freeze watchdog

    /// A background thread watches the main thread. If the UI hangs (system overlay, heavy
    /// redraw...) while anything is held, the PC is told to release everything right away,
    /// and when the UI comes back all touches are dropped so nothing re-presses by itself.
    private let wdLock = NSLock()
    private var wdAnyHeld = false
    private var wdLastBeat = CACurrentMediaTime()
    private var wdFired = false
    private var wdBeatPending = false
    private var watchdog: DispatchSourceTimer?
    private static let stallLimit: CFTimeInterval = 0.6

    private func updateHeldFlag() {
        let any = !keyCounts.isEmpty || !buttonCounts.isEmpty
        wdLock.lock(); wdAnyHeld = any; wdLock.unlock()
    }

    func startWatchdog() {
        guard watchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
        t.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(20))
        t.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = t
        t.resume()
    }

    private func watchdogTick() {
        let now = CACurrentMediaTime()
        wdLock.lock()
        let stalled = now - wdLastBeat > Self.stallLimit
        let fire = stalled && wdAnyHeld && !wdFired
        if fire { wdFired = true }
        let needBeat = !wdBeatPending
        if needBeat { wdBeatPending = true }
        wdLock.unlock()

        if fire { connection.emergencyReleaseAll() }
        if needBeat {
            DispatchQueue.main.async { [weak self] in self?.mainBeat() }
        }
    }

    private func mainBeat() {
        wdLock.lock()
        wdLastBeat = CACurrentMediaTime()
        wdBeatPending = false
        let recovered = wdFired
        wdFired = false
        wdLock.unlock()
        if recovered {
            NSLog("LocalKeys: main thread stalled with keys held; released everything")
            NotificationCenter.default.post(name: .lkStallRecovered, object: nil)
            resetLocal()
        }
    }

    // MARK: raw reference-counted keys

    func press(_ code: UInt16) {
        let n = (keyCounts[code] ?? 0) + 1
        keyCounts[code] = n
        if n == 1 {
            send(Proto.keyDown(code))
            if KeyCatalog.isModifier(code) { notify() }
        }
    }

    func release(_ code: UInt16) {
        guard let n = keyCounts[code] else { return }
        if n <= 1 {
            keyCounts[code] = nil
            send(Proto.keyUp(code))
            if KeyCatalog.isModifier(code) { notify() }
        } else {
            keyCounts[code] = n - 1
        }
    }

    // MARK: key touches (with optional sticky modifiers)

    func touchDown(_ code: UInt16) {
        let isMod = KeyCatalog.isModifier(code)
        if isMod && settings.stickyModifiers {
            if let state = latched[code] {
                consumeUp[code, default: 0] += 1
                if state == .oneShot {
                    latched[code] = .locked          // double tap: lock until tapped again
                } else {
                    latched[code] = nil              // tap on a locked modifier: unlock
                    release(code)
                }
                notify()
                return
            }
            modTaps[code] = (CACurrentMediaTime(), false)
        } else if !isMod {
            for k in modTaps.keys { modTaps[k]?.interrupted = true }
        }
        press(code)
    }

    func touchUp(_ code: UInt16) {
        if let n = consumeUp[code], n > 0 {
            consumeUp[code] = n > 1 ? n - 1 : nil
            return
        }
        let isMod = KeyCatalog.isModifier(code)
        if isMod && settings.stickyModifiers, let tap = modTaps.removeValue(forKey: code),
           !tap.interrupted, CACurrentMediaTime() - tap.time < 0.35, latched[code] == nil, (keyCounts[code] ?? 0) == 1 {
            latched[code] = .oneShot                 // quick tap: applies to the next key
            notify()
            return
        }
        modTaps.removeValue(forKey: code)
        release(code)
        if !isMod { consumeOneShots() }
    }

    private func consumeOneShots() {
        let shots = latched.filter { $0.value == .oneShot }.map { $0.key }
        guard !shots.isEmpty else { return }
        for k in shots {
            latched[k] = nil
            release(k)
        }
        notify()
    }

    // MARK: mouse

    func mouseDown(_ b: UInt8) {
        let n = (buttonCounts[b] ?? 0) + 1
        buttonCounts[b] = n
        if n == 1 { send(Proto.mouseButton(b, true)) }
    }

    func mouseUp(_ b: UInt8) {
        guard let n = buttonCounts[b] else { return }
        if n <= 1 {
            buttonCounts[b] = nil
            send(Proto.mouseButton(b, false))
            consumeOneShots()
        } else {
            buttonCounts[b] = n - 1
        }
    }

    func click(_ b: UInt8) {
        mouseDown(b)
        mouseUp(b)
    }

    func move(_ dx: Double, _ dy: Double) {
        remX += dx
        remY += dy
        let ix = Int(remX.rounded(.towardZero)), iy = Int(remY.rounded(.towardZero))
        if ix == 0 && iy == 0 { return }
        remX -= Double(ix)
        remY -= Double(iy)
        send(Proto.mouseMove(ix, iy))
    }

    /// Wheel units: 120 = one notch. Fractions are accumulated (smooth scrolling on modern apps).
    func scroll(vertical: Double, horizontal: Double) {
        remSV += vertical
        remSH += horizontal
        let v = Int(remSV.rounded(.towardZero)), h = Int(remSH.rounded(.towardZero))
        if v == 0 && h == 0 { return }
        remSV -= Double(v)
        remSH -= Double(h)
        send(Proto.scroll(v, h))
    }

    func text(_ s: String) {
        guard !s.isEmpty else { return }
        send(Proto.text(s))
    }

    func tapCombo(_ codes: [UInt16]) {
        codes.forEach { press($0) }
        codes.reversed().forEach { release($0) }
    }

    // MARK: sync

    func stateSyncFrame() -> Data {
        var mask: UInt8 = 0
        for (b, n) in buttonCounts where n > 0 && b < 8 { mask |= 1 << b }
        return Proto.stateSync(keys: Array(keyCounts.keys), buttons: mask)
    }

    func releaseAll() {
        keyCounts.removeAll()
        buttonCounts.removeAll()
        latched.removeAll()
        modTaps.removeAll()
        consumeUp.removeAll()
        send(Proto.frame(.releaseAll))
        notify()
    }

    /// Forget local state without talking to the PC (links are going away anyway).
    func resetLocal() {
        keyCounts.removeAll()
        buttonCounts.removeAll()
        latched.removeAll()
        modTaps.removeAll()
        consumeUp.removeAll()
        notify()
    }
}
