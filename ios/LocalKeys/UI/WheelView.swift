import UIKit

/// Scroll wheel strip: ridges roll under the finger like a real wheel, side ticks mark one
/// detent each, and the centre mark flashes on every step sent to the PC.
final class WheelView: ElementView {
    private let track = CALayer()
    private let ridges = CAReplicatorLayer()
    private let ridge = CALayer()
    private let shade = CAGradientLayer()
    private let ticks = CAShapeLayer()
    private let centerMarks = CAShapeLayer()
    private let icon = UIImageView()

    var notch: CGFloat = 26 { didSet { if notch != oldValue { setNeedsLayout() } } }
    private var phase: CGFloat = 0
    private var active = false

    var horizontal: Bool { bounds.width > bounds.height }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous
        track.masksToBounds = true
        track.addSublayer(ridges)
        ridges.addSublayer(ridge)
        layer.addSublayer(track)
        layer.addSublayer(shade)
        layer.addSublayer(ticks)
        layer.addSublayer(centerMarks)
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
        bringSubviewToFront(editHandle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(mode: WheelMode, notch: CGFloat) {
        icon.image = UIImage(systemName: mode.symbol, withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        self.notch = notch
    }

    func applyColors() {
        backgroundColor = active ? theme.zone.blended(with: theme.accent, 0.1) : theme.zone
        ridge.backgroundColor = theme.textDim.withAlphaComponent(0.42).cgColor
        let bg = (backgroundColor ?? theme.zone)
        shade.colors = [bg.cgColor, bg.withAlphaComponent(0).cgColor, bg.withAlphaComponent(0).cgColor, bg.cgColor]
        ticks.strokeColor = theme.textDim.withAlphaComponent(0.35).cgColor
        ticks.lineWidth = 1.5
        centerMarks.fillColor = theme.accent.cgColor
        centerMarks.opacity = active ? 0.9 : 0.45
        icon.tintColor = theme.textDim.withAlphaComponent(0.55)
        updateEditChrome()
        if !selectedForEdit && layer.borderWidth == 0 {
            layer.borderWidth = 1
            layer.borderColor = theme.zoneBorder.cgColor
        }
    }

    func setActive(_ on: Bool) {
        guard on != active else { return }
        active = on
        applyColors()
    }

    func setPhase(_ p: CGFloat) {
        phase = p
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let m = phase.truncatingRemainder(dividingBy: notch)
        let off = m < 0 ? m + notch : m
        ridges.transform = horizontal ? CATransform3DMakeTranslation(off, 0, 0) : CATransform3DMakeTranslation(0, off, 0)
        CATransaction.commit()
    }

    /// One step was sent: flash the centre mark.
    func pulse() {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = 1
        a.toValue = active ? 0.9 : 0.45
        a.duration = 0.18
        centerMarks.add(a, forKey: "pulse")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        let h = horizontal
        let iconSide: CGFloat = min(18, (h ? b.height : b.width) * 0.32)
        let iconArea = iconSide + 10
        // The rolling surface leaves room for the mode icon at the start (top / left).
        let trackRect = h ? CGRect(x: iconArea, y: 0, width: b.width - iconArea, height: b.height)
                          : CGRect(x: 0, y: iconArea, width: b.width, height: b.height - iconArea)
        icon.frame = h ? CGRect(x: 6, y: (b.height - iconSide) / 2, width: iconSide, height: iconSide)
                       : CGRect(x: (b.width - iconSide) / 2, y: 6, width: iconSide, height: iconSide)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = trackRect
        track.cornerRadius = min(layer.cornerRadius, 10)
        let margin: CGFloat = 10
        let length = h ? trackRect.width : trackRect.height
        ridges.frame = CGRect(origin: .zero, size: trackRect.size)
        ridges.instanceCount = Int(length / max(notch, 6)) + 3
        if h {
            ridge.frame = CGRect(x: -notch, y: margin, width: 2, height: trackRect.height - margin * 2)
            ridges.instanceTransform = CATransform3DMakeTranslation(notch, 0, 0)
        } else {
            ridge.frame = CGRect(x: margin, y: -notch, width: trackRect.width - margin * 2, height: 2)
            ridges.instanceTransform = CATransform3DMakeTranslation(0, notch, 0)
        }
        ridge.cornerRadius = 1

        // Cylinder shading: the surface fades towards both ends.
        shade.frame = trackRect
        shade.startPoint = h ? CGPoint(x: 0, y: 0.5) : CGPoint(x: 0.5, y: 0)
        shade.endPoint = h ? CGPoint(x: 1, y: 0.5) : CGPoint(x: 0.5, y: 1)
        shade.locations = [0, 0.28, 0.72, 1]

        // Static detent ticks along both sides, one per step.
        let tp = UIBezierPath()
        let tick: CGFloat = 5
        let center = h ? trackRect.midX : trackRect.midY
        var offsets: [CGFloat] = [0]
        var i: CGFloat = 1
        while i * notch < length / 2 - 4 {
            offsets += [i * notch, -i * notch]
            i += 1
        }
        for o in offsets {
            let s = center + o
            if h {
                tp.move(to: CGPoint(x: s, y: 2)); tp.addLine(to: CGPoint(x: s, y: 2 + tick))
                tp.move(to: CGPoint(x: s, y: b.height - 2)); tp.addLine(to: CGPoint(x: s, y: b.height - 2 - tick))
            } else {
                tp.move(to: CGPoint(x: 2, y: s)); tp.addLine(to: CGPoint(x: 2 + tick, y: s))
                tp.move(to: CGPoint(x: b.width - 2, y: s)); tp.addLine(to: CGPoint(x: b.width - 2 - tick, y: s))
            }
        }
        ticks.frame = b
        ticks.path = tp.cgPath

        // Centre marks: small triangles on both sides pointing at the reference line.
        let cm = UIBezierPath()
        let t: CGFloat = 6
        if h {
            cm.move(to: CGPoint(x: center - t, y: 0)); cm.addLine(to: CGPoint(x: center + t, y: 0)); cm.addLine(to: CGPoint(x: center, y: t * 1.2)); cm.close()
            cm.move(to: CGPoint(x: center - t, y: b.height)); cm.addLine(to: CGPoint(x: center + t, y: b.height)); cm.addLine(to: CGPoint(x: center, y: b.height - t * 1.2)); cm.close()
        } else {
            cm.move(to: CGPoint(x: 0, y: center - t)); cm.addLine(to: CGPoint(x: 0, y: center + t)); cm.addLine(to: CGPoint(x: t * 1.2, y: center)); cm.close()
            cm.move(to: CGPoint(x: b.width, y: center - t)); cm.addLine(to: CGPoint(x: b.width, y: center + t)); cm.addLine(to: CGPoint(x: b.width - t * 1.2, y: center)); cm.close()
        }
        centerMarks.frame = b
        centerMarks.path = cm.cgPath
        CATransaction.commit()
        setPhase(phase)
    }
}
