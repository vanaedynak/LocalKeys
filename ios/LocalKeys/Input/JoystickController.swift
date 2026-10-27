import UIKit
import CoreMotion

/// State of the virtual joystick on the PC (vJoy): 8 axes and 32 buttons. Axis changes are
/// coalesced (at most ~120 frames/s); button changes go out at once. Main thread only.
final class JoystickController {
    static let shared = JoystickController()

    private(set) var axes = [Int](repeating: 0, count: 8)
    private var buttons: UInt32 = 0
    private var buttonCounts: [UInt8: Int] = [:]
    /// Axes that keep their position when released (throttle): never auto-centred.
    private var holdMask: UInt8 = 0
    /// Something was sent since launch: resend the state on reconnect / transport switch.
    private var used = false
    private var flushScheduled = false
    private var lastFlush: CFTimeInterval = 0
    private static let minInterval: CFTimeInterval = 1.0 / 120

    private func frame() -> Data { Proto.joystick(axes: axes, buttons: buttons, hold: holdMask) }

    /// value: -1...1. `hold`: the axis stays where it was left (throttle).
    func setAxis(_ axis: JoyAxis, _ value: Double, hold: Bool) {
        let i = axis.rawValue
        let bit = UInt8(1 << i)
        holdMask = hold ? holdMask | bit : holdMask & ~bit
        let v = Int((max(-1, min(1, value)) * 32767).rounded())
        guard v != axes[i] else { return }
        axes[i] = v
        scheduleFlush()
    }

    func press(_ b: UInt8) {
        guard b >= 1, b <= 32 else { return }
        let n = (buttonCounts[b] ?? 0) + 1
        buttonCounts[b] = n
        if n == 1 {
            buttons |= 1 << UInt32(b - 1)
            flush()
        }
    }

    func release(_ b: UInt8) {
        guard let n = buttonCounts[b] else { return }
        if n <= 1 {
            buttonCounts[b] = nil
            buttons &= ~(1 << UInt32(b - 1))
            flush()
        } else {
            buttonCounts[b] = n - 1
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        let wait = lastFlush + Self.minInterval - CACurrentMediaTime()
        if wait <= 0 { flush(); return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.flushScheduled = false
            self?.flush()
        }
    }

    private func flush() {
        used = true
        lastFlush = CACurrentMediaTime()
        ConnectionManager.shared.send(frame())
    }

    /// New / switched link: the PC mirrors exactly the current stick, throttle and buttons.
    func resend() {
        if used { ConnectionManager.shared.send(frame()) }
    }

    /// Freeze recovery: drop buttons and centre the stick locally (the PC was already told).
    func resetLocal() {
        buttonCounts.removeAll()
        buttons = 0
        for i in axes.indices where holdMask & UInt8(1 << i) == 0 { axes[i] = 0 }
    }
}

/// Reads the iPad's tilt for the flight stick, relative to a calibrated "neutral" hold.
/// Tilting the right edge down rolls right; tilting the top edge away pushes the stick forward.
final class TiltController {
    static let shared = TiltController()

    private let motion = CMMotionManager()
    private var reference: (x: Double, y: Double)?
    private var running = false
    /// Normalised stick deflection: x roll (right +), y pitch (pulled back +), each -1...1.
    var onTilt: ((CGPoint) -> Void)?

    var available: Bool { motion.isDeviceMotionAvailable }

    func start() {
        guard !running, motion.isDeviceMotionAvailable else { return }
        running = true
        reference = nil
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(to: .main) { [weak self] m, _ in
            guard let self = self, let g = m?.gravity else { return }
            self.update(g)
        }
    }

    func stop() {
        guard running else { return }
        running = false
        motion.stopDeviceMotionUpdates()
    }

    /// The current hold becomes the neutral position.
    func recenter() { reference = nil }

    private var orientation: UIInterfaceOrientation = .landscapeRight
    private var orientationCheck = 0

    private func update(_ g: CMAcceleration) {
        // The interface orientation rarely changes: look it up a few times a second, not 60.
        orientationCheck += 1
        if orientationCheck % 15 == 1,
           let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {
            orientation = scene.interfaceOrientation
        }
        // Gravity in screen coordinates: x to the right, y to the top of the screen.
        let sx: Double, sy: Double
        switch orientation {
        case .landscapeRight: sx = -g.y; sy = g.x
        case .landscapeLeft: sx = g.y; sy = -g.x
        case .portraitUpsideDown: sx = -g.x; sy = -g.y
        default: sx = g.x; sy = g.y
        }
        let ax = asin(max(-1, min(1, sx)))
        let ay = asin(max(-1, min(1, sy)))
        guard let ref = reference else {
            reference = (ax, ay)
            onTilt?(.zero)
            return
        }
        let range = max(5, AppSettings.shared.tiltRange) * .pi / 180
        let dz = AppSettings.shared.tiltDeadzone
        func shape(_ a: Double) -> CGFloat {
            let v = max(-1, min(1, a / range))
            let m = max(0, abs(v) - dz) / (1 - dz)
            return CGFloat(v < 0 ? -m : m)
        }
        // Top edge down (gravity towards the top) = stick forward = negative Y, like a real stick.
        onTilt?(CGPoint(x: shape(ax - ref.x), y: shape(-(ay - ref.y))))
    }
}
