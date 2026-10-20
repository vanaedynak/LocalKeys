import UIKit

/// Turns touches inside a trackpad / mouse-look zone into pointer events.
/// Trackpad: 1 finger moves (with acceleration), tap = left click, tap-and-hold-drag = drag,
/// 2-finger tap = right click, 2-finger slide = scroll (with momentum), 3-finger tap = middle click.
/// Mouse look: raw, linear relative movement for game cameras; every finger counts.
final class TrackpadController: NSObject {
    enum Mode { case trackpad, mouseLook }

    private struct TouchInfo {
        var start: CGPoint
        var last: CGPoint
        var lastTime: TimeInterval
    }

    let mode: Mode
    private var touches: [ObjectIdentifier: TouchInfo] = [:]
    private var maxCount = 0
    private var gestureStart: TimeInterval = 0
    private var travel: CGFloat = 0
    private var lastTapEnd: TimeInterval = -10
    private var dragHeld = false
    private var scrollVelocity = CGPoint.zero
    private var lastScrollTime: TimeInterval = 0
    private var displayLink: CADisplayLink?
    private var momentum = CGPoint.zero
    private var lastFrame: CFTimeInterval = 0

    private var input: InputController { .shared }
    private var s: AppSettings { .shared }

    init(mode: Mode) {
        self.mode = mode
        super.init()
    }

    var isActive: Bool { !touches.isEmpty }

    func began(_ t: UITouch, in view: UIView) {
        let p = t.location(in: view)
        if touches.isEmpty {
            stopMomentum()
            maxCount = 0
            travel = 0
            gestureStart = t.timestamp
            scrollVelocity = .zero
            if mode == .trackpad, s.tapToClick, t.timestamp - lastTapEnd < 0.3 {
                // Tap, then touch again quickly: hold the left button (drag / double click).
                input.mouseDown(0)
                dragHeld = true
            }
        }
        touches[ObjectIdentifier(t)] = TouchInfo(start: p, last: p, lastTime: t.timestamp)
        maxCount = max(maxCount, touches.count)
    }

    func moved(_ t: UITouch, event: UIEvent?, in view: UIView) {
        let key = ObjectIdentifier(t)
        guard var info = touches[key] else { return }
        // Coalesced touches give the full touch sampling rate, not just one sample per frame.
        var samples = event?.coalescedTouches(for: t) ?? [t]
        if samples.isEmpty { samples = [t] }
        for sample in samples {
            let p = sample.location(in: view)
            let dx = p.x - info.last.x, dy = p.y - info.last.y
            let dt = max(sample.timestamp - info.lastTime, 1.0 / 240.0)
            info.last = p
            info.lastTime = sample.timestamp
            travel += hypot(dx, dy)
            apply(dx: dx, dy: dy, dt: dt, timestamp: sample.timestamp)
        }
        touches[key] = info
    }

    private func apply(dx: CGFloat, dy: CGFloat, dt: TimeInterval, timestamp: TimeInterval) {
        switch mode {
        case .mouseLook:
            let g = 2.0 * s.lookSpeed
            input.move(Double(dx) * g, Double(dy) * g * (s.invertLookY ? -1 : 1))
        case .trackpad:
            if maxCount == 1 {
                let speed = Double(hypot(dx, dy)) / dt
                let gain = pointerGain(speed)
                input.move(Double(dx) * gain, Double(dy) * gain)
            } else if maxCount == 2 && touches.count == 2 {
                // Each finger contributes half of the gesture translation.
                emitScroll(dx: dx * 0.5, dy: dy * 0.5)
                let vx = dx / CGFloat(dt), vy = dy / CGFloat(dt)
                scrollVelocity = CGPoint(x: scrollVelocity.x * 0.6 + vx * 0.4, y: scrollVelocity.y * 0.6 + vy * 0.4)
                lastScrollTime = timestamp
            }
        }
    }

    private func pointerGain(_ speed: Double) -> Double {
        let base = 1.5 * s.pointerSpeed
        let boost = min(max((speed - 120) / 650, 0), 2.6)
        return base * (1 + s.pointerAccel * boost)
    }

    private func emitScroll(dx: CGFloat, dy: CGFloat) {
        let k = 4.0 * s.scrollSpeed
        let sign: Double = s.naturalScroll ? 1 : -1
        input.scroll(vertical: Double(dy) * k * sign, horizontal: -Double(dx) * k * sign)
    }

    func ended(_ t: UITouch, cancelled: Bool) {
        guard touches.removeValue(forKey: ObjectIdentifier(t)) != nil else { return }
        guard touches.isEmpty else { return }
        guard mode == .trackpad else { return }

        let duration = t.timestamp - gestureStart
        let isTap = !cancelled && travel < 14 && duration < 0.28
        if dragHeld {
            input.mouseUp(0)
            dragHeld = false
            lastTapEnd = -10
            return
        }
        if isTap && s.tapToClick {
            switch maxCount {
            case 1:
                input.click(0)
                lastTapEnd = t.timestamp
            case 2:
                input.click(1)
            default:
                input.click(2)
            }
            return
        }
        if maxCount == 2, !cancelled, s.scrollMomentum, t.timestamp - lastScrollTime < 0.06,
           hypot(scrollVelocity.x, scrollVelocity.y) > 280 {
            startMomentum(scrollVelocity)
        }
    }

    func cancelAll() {
        touches.removeAll()
        if dragHeld {
            input.mouseUp(0)
            dragHeld = false
        }
        stopMomentum()
    }

    // MARK: momentum scrolling

    private func startMomentum(_ v: CGPoint) {
        momentum = v
        lastFrame = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopMomentum() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastFrame, 0.05)
        lastFrame = now
        emitScroll(dx: momentum.x * CGFloat(dt), dy: momentum.y * CGFloat(dt))
        let decay = CGFloat(pow(0.935, dt * 60))
        momentum = CGPoint(x: momentum.x * decay, y: momentum.y * decay)
        if hypot(momentum.x, momentum.y) < 25 { stopMomentum() }
    }
}
