import UIKit

/// Flight stick: a square field with a crosshair; the knob shows the current deflection
/// (from the finger or from the iPad's tilt).
final class FlightStickView: ElementView {
    private let cross = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let knob = UIView()
    private let label = UILabel()
    private let status = UILabel()
    private var value: CGPoint = .zero
    var tilt = false { didSet { if tilt != oldValue { updateText() } } }
    var touching = false { didSet { if touching != oldValue { applyColors() } } }
    var caption = "" { didSet { updateText() } }
    /// Problem shown in the middle (e.g. "vJoy is not installed on the PC").
    var problem: String? { didSet { if problem != oldValue { updateText() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        layer.addSublayer(cross)
        layer.addSublayer(ring)
        addSubview(knob)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textAlignment = .center
        addSubview(label)
        status.font = .systemFont(ofSize: 13, weight: .medium)
        status.textAlignment = .center
        status.numberOfLines = 3
        addSubview(status)
        bringSubviewToFront(editHandle)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var travel: CGFloat { min(bounds.width, bounds.height) * 0.42 }

    func applyColors() {
        backgroundColor = touching ? theme.zone.blended(with: theme.accent, 0.08) : theme.zone
        cross.strokeColor = theme.zoneBorder.cgColor
        cross.lineWidth = 1.5
        cross.fillColor = UIColor.clear.cgColor
        ring.strokeColor = theme.accent.withAlphaComponent(0.25).cgColor
        ring.fillColor = UIColor.clear.cgColor
        ring.lineWidth = 1.5
        ring.lineDashPattern = [5, 5]
        knob.backgroundColor = theme.accent.withAlphaComponent(0.85)
        knob.layer.borderColor = UIColor.white.withAlphaComponent(0.7).cgColor
        knob.layer.borderWidth = 2
        label.textColor = theme.textDim.withAlphaComponent(0.7)
        status.textColor = theme.latched
        updateEditChrome()
    }

    private func updateText() {
        label.text = caption.isEmpty ? (tilt ? "Наклон iPad · двойное касание — центр" : "Ручка") : caption
        status.text = problem
        status.isHidden = problem == nil
    }

    /// x: roll (right +), y: pitch (pulled back / down +), each -1...1.
    func setValue(_ v: CGPoint) {
        value = v
        let r = travel
        let s = max(min(bounds.width, bounds.height) * 0.14, 22)
        knob.frame = CGRect(x: bounds.midX + v.x * r - s / 2, y: bounds.midY + v.y * r - s / 2, width: s, height: s)
        knob.layer.cornerRadius = s / 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let r = travel
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let p = UIBezierPath()
        p.move(to: CGPoint(x: c.x - r, y: c.y)); p.addLine(to: CGPoint(x: c.x + r, y: c.y))
        p.move(to: CGPoint(x: c.x, y: c.y - r)); p.addLine(to: CGPoint(x: c.x, y: c.y + r))
        cross.frame = bounds
        cross.path = p.cgPath
        ring.frame = bounds
        ring.path = UIBezierPath(roundedRect: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2), cornerRadius: r * 0.25).cgPath
        label.frame = CGRect(x: 8, y: bounds.height - 24, width: bounds.width - 16, height: 18)
        status.frame = CGRect(x: 16, y: bounds.height * 0.18, width: bounds.width - 32, height: 60)
        setValue(value)
    }
}

/// One joystick axis as a slider: throttle (fills from the bottom / left and stays) or
/// rudder (springs to the middle). Vertical or horizontal by the element's shape.
final class AxisView: ElementView {
    private let fill = UIView()
    private let handle = UIView()
    private let centerLine = UIView()
    private let label = UILabel()
    private let percent = UILabel()
    var spring = false { didSet { setNeedsLayout() } }
    var caption = "" { didSet { label.text = caption } }
    private var value: Double = -1
    var touching = false { didSet { if touching != oldValue { applyColors() } } }

    var horizontal: Bool { bounds.width > bounds.height }
    /// Length of the travel in points.
    var length: CGFloat { horizontal ? bounds.width : bounds.height }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        clipsToBounds = true
        addSubview(fill)
        addSubview(centerLine)
        addSubview(handle)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textAlignment = .center
        addSubview(label)
        percent.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        percent.textAlignment = .center
        addSubview(percent)
        bringSubviewToFront(editHandle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func applyColors() {
        backgroundColor = touching ? theme.zone.blended(with: theme.accent, 0.08) : theme.zone
        fill.backgroundColor = theme.accent.withAlphaComponent(0.28)
        handle.backgroundColor = theme.accent
        centerLine.backgroundColor = theme.zoneBorder
        label.textColor = theme.text
        percent.textColor = theme.textDim
        updateEditChrome()
    }

    /// -1...1
    func setValue(_ v: Double) {
        value = v
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        let t = CGFloat((value + 1) / 2)            // 0...1 along the travel
        let hs: CGFloat = 6
        centerLine.isHidden = !spring
        if horizontal {
            let x = w * t
            fill.frame = spring ? CGRect(x: min(x, w / 2), y: 0, width: abs(x - w / 2), height: h) : CGRect(x: 0, y: 0, width: x, height: h)
            handle.frame = CGRect(x: x - hs / 2, y: 0, width: hs, height: h)
            centerLine.frame = CGRect(x: w / 2 - 1, y: 0, width: 2, height: h)
            label.frame = CGRect(x: 8, y: h / 2 - 20, width: w - 16, height: 20)
            percent.frame = CGRect(x: 8, y: h / 2, width: w - 16, height: 18)
        } else {
            let y = h * (1 - t)                        // up = more
            fill.frame = spring ? CGRect(x: 0, y: min(y, h / 2), width: w, height: abs(y - h / 2)) : CGRect(x: 0, y: y, width: w, height: h - y)
            handle.frame = CGRect(x: 0, y: y - hs / 2, width: w, height: hs)
            centerLine.frame = CGRect(x: 0, y: h / 2 - 1, width: w, height: 2)
            label.frame = CGRect(x: 4, y: 10, width: w - 8, height: 20)
            percent.frame = CGRect(x: 4, y: 30, width: w - 8, height: 18)
        }
        handle.layer.cornerRadius = hs / 2
        percent.text = spring ? String(format: "%+d", Int((value * 100).rounded())) : "\(Int((Double(t) * 100).rounded()))%"
    }
}
