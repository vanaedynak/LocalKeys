import UIKit

/// Visual for one element. Purely presentational: all touches are handled by KeyboardView.
class ElementView: UIView {
    var theme: KTheme = .midnight
    var selectedForEdit = false { didSet { updateEditChrome() } }
    let editHandle = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        editHandle.isHidden = true
        editHandle.layer.cornerRadius = 9
        editHandle.layer.borderWidth = 2
        addSubview(editHandle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        editHandle.frame = CGRect(x: bounds.width - 14, y: bounds.height - 14, width: 18, height: 18)
    }

    func updateEditChrome() {
        editHandle.isHidden = !selectedForEdit
        editHandle.backgroundColor = theme.accent
        editHandle.layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = selectedForEdit ? 2.5 : (theme.border == .clear ? 0 : 1)
        layer.borderColor = selectedForEdit ? theme.accent.cgColor : theme.border.cgColor
        if selectedForEdit { bringSubviewToFront(editHandle) }
    }
}

final class KeyCapView: ElementView {
    private let mainLabel = UILabel()
    private let topLabel = UILabel()
    private let altLabel = UILabel()
    private let captionLabel = UILabel()
    private let icon = UIImageView()
    private let led = UIView()

    var style: KeyStyle = .normal
    private(set) var pressed = false
    private(set) var latched = false
    var ledOn: Bool? = nil { didSet { if ledOn != oldValue { setNeedsLayout(); applyColors() } } }

    private var mainText = ""
    private var topText = ""
    private var altText = ""
    private var captionText = ""
    private var symbolName: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 9
        layer.cornerCurve = .continuous
        for l in [mainLabel, topLabel, altLabel, captionLabel] {
            l.textAlignment = .center
            l.adjustsFontSizeToFitWidth = true
            l.minimumScaleFactor = 0.45
            l.baselineAdjustment = .alignCenters
            addSubview(l)
        }
        topLabel.textAlignment = .left
        altLabel.textAlignment = .right
        icon.contentMode = .scaleAspectFit
        addSubview(icon)
        led.layer.cornerRadius = 2.5
        addSubview(led)
        bringSubviewToFront(editHandle)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// main: big centre text. top: small top-left (shifted symbol). alt: small bottom-right (second language).
    /// Text starting with "sf:" is an SF Symbol; "sf:name|Caption" shows an icon with a caption.
    private var lastLegend: (String, String, String)?

    func setLegend(main: String, top: String = "", alt: String = "") {
        if let l = lastLegend, l == (main, top, alt) { return }
        lastLegend = (main, top, alt)
        if main.hasPrefix("sf:") {
            let body = String(main.dropFirst(3))
            let parts = body.split(separator: "|", maxSplits: 1).map(String.init)
            symbolName = parts.first
            captionText = parts.count > 1 ? parts[1] : ""
            mainText = ""
        } else {
            symbolName = nil
            captionText = ""
            mainText = main
        }
        topText = top
        altText = alt
        mainLabel.text = mainText
        topLabel.text = topText
        altLabel.text = altText
        captionLabel.text = captionText
        if let s = symbolName {
            icon.image = UIImage(systemName: s, withConfiguration: UIImage.SymbolConfiguration(weight: .medium))
            icon.isHidden = false
        } else {
            icon.image = nil
            icon.isHidden = true
        }
        setNeedsLayout()
    }

    func setState(pressed: Bool, latched: Bool) {
        if pressed == self.pressed && latched == self.latched { return }
        self.pressed = pressed
        self.latched = latched
        applyColors()
    }

    func applyColors() {
        let base: UIColor
        switch style {
        case .mod, .auto: base = theme.keyMod
        case .accent: base = theme.keyAccent
        case .danger: base = theme.keyDanger
        case .normal: base = theme.key
        }
        backgroundColor = pressed ? theme.pressed : base
        let fg: UIColor = pressed ? (theme.isLight ? .white : UIColor(white: 0.04, alpha: 1)) :
            ((style == .accent || style == .danger) ? .white : theme.text)
        mainLabel.textColor = fg
        captionLabel.textColor = (pressed || style == .accent || style == .danger) ? fg.withAlphaComponent(0.92) : theme.textDim
        icon.tintColor = fg
        topLabel.textColor = pressed ? fg.withAlphaComponent(0.8) : theme.textDim
        altLabel.textColor = pressed ? fg.withAlphaComponent(0.8) : theme.accent.withAlphaComponent(0.85)
        led.isHidden = ledOn == nil
        led.backgroundColor = (ledOn ?? false) ? theme.latched : theme.textDim.withAlphaComponent(0.25)
        if latched && !pressed {
            layer.borderWidth = 2
            layer.borderColor = theme.latched.cgColor
        } else {
            updateEditChrome()
        }
        if theme.shadow {
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = pressed ? 0 : (theme.isLight ? 0.18 : 0.35)
            layer.shadowRadius = 0
            layer.shadowOffset = CGSize(width: 0, height: 1.5)
        } else {
            layer.shadowOpacity = 0
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let w = bounds.width, h = bounds.height
        let unit = min(w, h)
        let hasSub = !topText.isEmpty || !altText.isEmpty
        let mainSize = min(unit * (mainText.count > 2 ? 0.27 : 0.4), 30)
        mainLabel.font = .systemFont(ofSize: mainText.count > 2 ? max(mainSize, 11) : mainSize, weight: .medium)
        let small = max(min(unit * 0.22, 15), 8)
        topLabel.font = .systemFont(ofSize: small, weight: .regular)
        altLabel.font = .systemFont(ofSize: small, weight: .semibold)
        captionLabel.font = .systemFont(ofSize: max(min(unit * 0.17, 13), 8), weight: .medium)

        let inset: CGFloat = max(unit * 0.1, 4)
        if symbolName != nil {
            let side = min(unit * (captionText.isEmpty ? 0.42 : 0.36), 30)
            let iconY = captionText.isEmpty ? (h - side) / 2 : h * 0.42 - side / 2
            icon.frame = CGRect(x: (w - side) / 2, y: iconY, width: side, height: side)
            captionLabel.frame = CGRect(x: inset, y: h * 0.62, width: w - inset * 2, height: h * 0.3)
            mainLabel.frame = .zero
        } else {
            icon.frame = .zero
            captionLabel.frame = .zero
            if hasSub && mainText.count <= 2 {
                mainLabel.frame = CGRect(x: inset, y: h * 0.2, width: w - inset * 2, height: h * 0.62)
            } else {
                mainLabel.frame = bounds.insetBy(dx: inset, dy: inset * 0.5)
            }
        }
        topLabel.frame = CGRect(x: inset, y: inset * 0.6, width: w - inset * 2, height: small * 1.3)
        altLabel.frame = CGRect(x: inset, y: h - inset * 0.6 - small * 1.3, width: w - inset * 2, height: small * 1.3)
        led.frame = CGRect(x: w - inset - 6, y: inset, width: 6, height: 6)
        layer.cornerRadius = min(10, unit * 0.16)
    }
}

/// Trackpad / mouse-look zone.
final class ZoneView: ElementView {
    private let iconView = UIImageView()
    private let label = UILabel()
    private let dash = CAShapeLayer()
    var active = false { didSet { if active != oldValue { applyColors() } } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        iconView.contentMode = .scaleAspectFit
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        addSubview(iconView)
        addSubview(label)
        layer.addSublayer(dash)
        bringSubviewToFront(editHandle)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(symbol: String, text: String) {
        iconView.image = UIImage(systemName: symbol)
        label.text = text
    }

    func applyColors() {
        backgroundColor = active ? theme.zone.blended(with: theme.accent, 0.08) : theme.zone
        iconView.tintColor = theme.textDim.withAlphaComponent(active ? 0.5 : 0.28)
        label.textColor = theme.textDim.withAlphaComponent(active ? 0.6 : 0.4)
        dash.strokeColor = theme.zoneBorder.cgColor
        dash.fillColor = UIColor.clear.cgColor
        dash.lineWidth = 1.5
        dash.lineDashPattern = [6, 5]
        updateEditChrome()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let side = min(bounds.width, bounds.height) * 0.22
        iconView.frame = CGRect(x: (bounds.width - side) / 2, y: bounds.height / 2 - side * 0.75, width: side, height: side)
        label.frame = CGRect(x: 8, y: bounds.height / 2 + side * 0.35, width: bounds.width - 16, height: 20)
        dash.frame = bounds
        dash.path = UIBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: 13).cgPath
    }
}

/// Virtual analog stick mapped to keys (WASD by default).
final class StickView: ElementView {
    let base = UIView()
    let knob = UIView()
    private let label = UILabel()
    var center0: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        addSubview(base)
        addSubview(knob)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textAlignment = .center
        addSubview(label)
        bringSubviewToFront(editHandle)
    }

    required init?(coder: NSCoder) { fatalError() }

    var radius: CGFloat { min(bounds.width, bounds.height) * 0.32 }

    func applyColors(text: String) {
        backgroundColor = theme.zone
        base.backgroundColor = theme.keyMod
        base.layer.borderColor = theme.zoneBorder.cgColor
        base.layer.borderWidth = 1.5
        knob.backgroundColor = theme.key
        knob.layer.borderColor = theme.accent.withAlphaComponent(0.6).cgColor
        knob.layer.borderWidth = 2
        label.textColor = theme.textDim.withAlphaComponent(0.6)
        label.text = text
        updateEditChrome()
    }

    func setKnob(center: CGPoint?, offset: CGPoint) {
        let c = center ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let r = radius
        base.frame = CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        base.layer.cornerRadius = r
        let kr = r * 0.48
        knob.frame = CGRect(x: c.x + offset.x - kr, y: c.y + offset.y - kr, width: kr * 2, height: kr * 2)
        knob.layer.cornerRadius = kr
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if center0 == nil { setKnob(center: nil, offset: .zero) }
        label.frame = CGRect(x: 0, y: bounds.height - 22, width: bounds.width, height: 18)
    }
}

extension UIColor {
    func blended(with other: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
