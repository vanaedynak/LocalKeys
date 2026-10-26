import UIKit
import AudioToolbox

/// Turns one finger sliding along a wheel strip into detent steps: one step per `notch` points.
/// Scroll: a mouse wheel notch (120 = 3 lines in Windows) or smooth pixels. Other modes send keys.
/// Tap: middle click (scroll) / mute (volume). A flick keeps a scroll wheel spinning for a moment.
final class WheelController: NSObject {
    private(set) var config: WheelConfig
    private weak var view: WheelView?

    private var touch: ObjectIdentifier?
    private var lastPos: CGFloat = 0
    private var lastTime: TimeInterval = 0
    private var startTime: TimeInterval = 0
    private var travel: CGFloat = 0
    private var acc: CGFloat = 0
    private var phase: CGFloat = 0
    private var velocity: CGFloat = 0
    private var heldMods: [UInt16] = []
    private var spinLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0
    private var lastClick: CFTimeInterval = 0

    private var input: InputController { .shared }
    private var settings: AppSettings { .shared }

    init(config: WheelConfig, view: WheelView) {
        self.config = config
        self.view = view
        super.init()
        view.configure(mode: config.mode, notch: notch)
    }

    var notch: CGFloat { CGFloat(max(config.notch ?? 26, 8)) }
    var busy: Bool { touch != nil }

    private func axis(_ p: CGPoint) -> CGFloat {
        (view?.horizontal ?? false) ? p.x : p.y
    }

    func began(_ t: UITouch, in host: UIView) {
        stopSpin()
        touch = ObjectIdentifier(t)
        lastPos = axis(t.location(in: host))
        lastTime = t.timestamp
        startTime = t.timestamp
        travel = 0
        velocity = 0
        acc = 0
        view?.setActive(true)
    }

    func moved(_ t: UITouch, event: UIEvent?, in host: UIView) {
        guard touch == ObjectIdentifier(t) else { return }
        var samples = event?.coalescedTouches(for: t) ?? [t]
        if samples.isEmpty { samples = [t] }
        for s in samples {
            let pos = axis(s.location(in: host))
            let d = pos - lastPos
            let dt = max(s.timestamp - lastTime, 1.0 / 240.0)
            lastPos = pos
            lastTime = s.timestamp
            travel += abs(d)
            velocity = velocity * 0.6 + (d / CGFloat(dt)) * 0.4
            advance(d)
        }
    }

    func ended(_ t: UITouch, cancelled: Bool) {
        guard touch == ObjectIdentifier(t) else { return }
        touch = nil
        if !cancelled, travel < 8, t.timestamp - startTime < 0.25 {
            tap()
        } else if !cancelled, config.mode.isScroll, config.spin ?? true,
                  abs(velocity) > 450, t.timestamp - lastTime < 0.05 {
            startSpin()
            return
        }
        finish()
    }

    /// Layout switch, app in background, freeze recovery: stop everything, release modifiers.
    func cancelAll() {
        touch = nil
        stopSpin()
        finish()
    }

    private func finish() {
        for m in heldMods.reversed() { input.release(m) }
        heldMods.removeAll()
        acc = 0
        view?.setActive(false)
    }

    // MARK: steps

    /// d > 0: finger moved down (vertical strip) or right (horizontal strip).
    private func advance(_ d: CGFloat) {
        phase += d
        view?.setPhase(phase)
        let smooth = config.mode.isScroll && config.smooth == true
        if smooth { emitSmooth(d) }
        acc += d
        while acc >= notch { acc -= notch; step(+1, send: !smooth) }
        while acc <= -notch { acc += notch; step(-1, send: !smooth) }
    }

    private var sign: Double { config.invert == true ? -1 : 1 }

    private func emitSmooth(_ d: CGFloat) {
        let units = Double(d / notch) * 120 * sign * (settings.naturalScroll ? 1 : -1)
        if config.mode == .scroll { input.scroll(vertical: units, horizontal: 0) }
        else { input.scroll(vertical: 0, horizontal: -units) }
    }

    private func step(_ dir: Int, send: Bool) {
        view?.pulse()
        click()
        guard send else { return }
        let d = Double(dir) * sign
        let horizontal = view?.horizontal ?? false
        // "Forward" = up on a vertical strip, right on a horizontal one.
        let forward = horizontal ? d > 0 : d < 0
        switch config.mode {
        case .scroll:
            input.scroll(vertical: d * 120 * (settings.naturalScroll ? 1 : -1), horizontal: 0)
        case .hscroll:
            input.scroll(vertical: 0, horizontal: -d * 120 * (settings.naturalScroll ? 1 : -1))
        case .volume:
            tapKey(forward ? KC.volUp : KC.volDown)
        case .zoom:
            hold(KC.lctrl)
            input.scroll(vertical: forward ? 120 : -120, horizontal: 0)
        case .tabs:
            hold(KC.lctrl)
            if d > 0 { tapKey(KC.tab) } else { tapKey(KC.tab, shift: true) }
        case .windows:
            // Alt stays down while the finger is on the wheel: the switcher stays open,
            // lifting the finger picks the window.
            hold(KC.lalt)
            if d > 0 { tapKey(KC.tab) } else { tapKey(KC.tab, shift: true) }
        case .undo:
            hold(KC.lctrl)
            tapKey(d > 0 ? KC.y : KC.z)
        case .arrows:
            if horizontal { tapKey(d > 0 ? KC.right : KC.left) }
            else { tapKey(d > 0 ? KC.down : KC.up) }
        }
    }

    private func tap() {
        switch config.mode {
        case .scroll, .hscroll: input.click(2)
        case .volume: tapKey(KC.volMute)
        default: break
        }
    }

    private func hold(_ code: UInt16) {
        guard !heldMods.contains(code) else { return }
        heldMods.append(code)
        input.press(code)
    }

    private func tapKey(_ code: UInt16, shift: Bool = false) {
        if shift { input.press(KC.lshift) }
        input.press(code)
        input.release(code)
        if shift { input.release(KC.lshift) }
    }

    private func click() {
        guard settings.keySound else { return }
        let now = CACurrentMediaTime()
        if now - lastClick < 0.035 { return }
        lastClick = now
        AudioServicesPlaySystemSound(1104)
    }

    // MARK: free spin

    private func startSpin() {
        stopSpin()
        lastFrame = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(spinStep))
        link.add(to: .main, forMode: .common)
        spinLink = link
    }

    private func stopSpin() {
        spinLink?.invalidate()
        spinLink = nil
    }

    @objc private func spinStep(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastFrame, 0.05)
        lastFrame = now
        advance(velocity * CGFloat(dt))
        velocity *= CGFloat(pow(0.94, dt * 60))
        if abs(velocity) < 70 {
            stopSpin()
            finish()
        }
    }
}
