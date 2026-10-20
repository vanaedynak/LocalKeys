import UIKit
import AudioToolbox

/// The touch surface. Every UITouch is tracked individually, so any number of keys can be held
/// at once (WASD + Shift + Space + mouse look...), each with its own press and release.
final class KeyboardView: UIView {
    private(set) var layout: KBLayout = BuiltinLayouts.laptop
    private var theme: KTheme = .midnight
    private var gap: CGFloat = 5
    private var vpos: CGFloat = 0.5
    private var scale: CGFloat = 1
    /// Number of Fn keys currently held: the second layer is active while > 0.
    private var fnHeld = 0
    private(set) var editing = false
    private(set) var selectedId: UUID?

    var onSelect: ((UUID?) -> Void)?
    var onEdited: ((KBLayout) -> Void)?
    var onSpecial: ((SpecialAction) -> Void)?
    var onSwitchLayout: ((String) -> Void)?

    private var views: [UUID: ElementView] = [:]
    private var cells: [UUID: CGRect] = [:]
    private var index: [UUID: Int] = [:]
    private var ux: CGFloat = 1
    private var uy: CGFloat = 1

    private struct EditOp {
        let id: UUID
        let resize: Bool
        let start: CGPoint
        let orig: KeyDef
    }

    private enum Binding {
        case key(UUID, Bool)   // element, pressed on the Fn layer
        case zone(UUID)
        case stick(UUID)
        case edit(EditOp)
        case ignored
    }

    private struct StickState {
        var center: CGPoint
        var held: Set<UInt16>
    }

    private var bindings: [ObjectIdentifier: Binding] = [:]
    private var pressCount: [UUID: Int] = [:]
    private var toggled: Set<UUID> = []
    private var zones: [UUID: TrackpadController] = [:]
    private var sticks: [UUID: StickState] = [:]
    private var legends = Legends.Resolved(primary: Legends.en, primaryLang: "EN", secondary: nil)
    private var observers: [NSObjectProtocol] = []
    private var built = false

    private let input = InputController.shared
    private var settings: AppSettings { .shared }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        isExclusiveTouch = false
        backgroundColor = .clear
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .lkLegendsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateLegends()
        })
        observers.append(nc.addObserver(forName: .lkInputStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateLegends()
            self?.refreshStates()
        })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.releaseAllTouches()
        })
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }

    // MARK: configuration

    func apply(layout: KBLayout, theme: KTheme, gap: CGFloat, editing: Bool, selectedId: UUID?,
               vpos: CGFloat, scale: CGFloat) {
        if vpos != self.vpos || scale != self.scale {
            self.vpos = vpos
            self.scale = scale
            setNeedsLayout()
        }
        if editing != self.editing {
            releaseAllTouches()
            self.editing = editing
        }
        let themeChanged = theme.id != self.theme.id || gap != self.gap
        self.theme = theme
        self.gap = gap
        let dragging = bindings.values.contains { if case .edit = $0 { return true } else { return false } }
        if !built || (layout != self.layout && !dragging) {
            if layout.id != self.layout.id || !editing { releaseAllTouches() }
            self.layout = layout
            rebuild()
        } else if themeChanged {
            restyle()
            setNeedsLayout()
        }
        if selectedId != self.selectedId {
            self.selectedId = selectedId
        }
        updateSelection()
        updateLegends()
    }

    private func rebuild() {
        built = true
        views.values.forEach { $0.removeFromSuperview() }
        views.removeAll()
        zones.removeAll()
        sticks.removeAll()
        index.removeAll()
        for (i, k) in layout.keys.enumerated() {
            index[k.id] = i
            let v: ElementView
            switch k.action {
            case .trackpad:
                let z = ZoneView()
                z.configure(symbol: "hand.point.up.left", text: k.label ?? "Тачпад")
                zones[k.id] = TrackpadController(mode: .trackpad)
                v = z
            case .mouseLook:
                let z = ZoneView()
                z.configure(symbol: "scope", text: k.label ?? "Обзор мышью")
                zones[k.id] = TrackpadController(mode: .mouseLook)
                v = z
            case .stick:
                v = StickView()
            default:
                let c = KeyCapView()
                c.style = k.resolvedStyle()
                v = c
            }
            addSubview(v)
            views[k.id] = v
        }
        restyle()
        updateLegends()
        refreshStates()
        updateSelection()
        setNeedsLayout()
    }

    private func restyle() {
        for k in layout.keys {
            guard let v = views[k.id] else { continue }
            v.theme = theme
            if let c = v as? KeyCapView {
                c.applyColors()
            } else if let z = v as? ZoneView {
                z.applyColors()
            } else if let s = v as? StickView {
                s.applyColors(text: k.label ?? "")
            }
        }
    }

    private func updateSelection() {
        for (id, v) in views {
            let sel = editing && id == selectedId
            if v.selectedForEdit != sel { v.selectedForEdit = sel }
        }
    }

    // MARK: geometry

    override func layoutSubviews() {
        super.layoutSubviews()
        let pad: CGFloat = 6
        let availW = max(bounds.width - pad * 2, 1)
        let availH = max(bounds.height - pad * 2, 1)
        var x = availW / CGFloat(max(layout.cols, 1))
        var y = availH / CGFloat(max(layout.rows, 1))
        // Allow keys to be somewhat taller or wider than square to use the screen well.
        if y > x * 1.3 { y = x * 1.3 }
        if x > y * 1.6 { x = y * 1.6 }
        x *= scale
        y *= scale
        ux = x
        uy = y
        let w = x * CGFloat(layout.cols), h = y * CGFloat(layout.rows)
        let ox = (bounds.width - w) / 2
        let oy = max(0, bounds.height - h) * min(max(vpos, 0), 1)
        for k in layout.keys {
            let cell = CGRect(x: ox + CGFloat(k.x) * x, y: oy + CGFloat(k.y) * y, width: CGFloat(k.w) * x, height: CGFloat(k.h) * y)
            cells[k.id] = cell
            guard let v = views[k.id] else { continue }
            let f = cell.insetBy(dx: gap / 2, dy: gap / 2)
            if v.frame != f {
                v.frame = f
                if let s = v as? StickView, sticks[k.id] == nil {
                    s.center0 = nil
                    s.setNeedsLayout()
                }
            }
        }
    }

    private func element(at p: CGPoint) -> KeyDef? {
        for k in layout.keys.reversed() where cells[k.id]?.contains(p) == true {
            return k
        }
        // In a gap / just outside: snap to the nearest key within a small slack.
        var best: (KeyDef, CGFloat)?
        let slack: CGFloat = 14
        for k in layout.keys where !k.action.isZone {
            guard let c = cells[k.id] else { continue }
            let dx = max(c.minX - p.x, 0, p.x - c.maxX)
            let dy = max(c.minY - p.y, 0, p.y - c.maxY)
            let d = hypot(dx, dy)
            if d < slack && d < (best?.1 ?? .greatestFiniteMagnitude) { best = (k, d) }
        }
        return best?.0
    }

    private func keyDef(_ id: UUID) -> KeyDef? {
        guard let i = index[id], i < layout.keys.count, layout.keys[i].id == id else {
            return layout.keys.first { $0.id == id }
        }
        return layout.keys[i]
    }

    // MARK: legends & visual state

    private func isLetter(_ s: String) -> Bool { s.first?.isLetter ?? false }

    private func effective(_ k: KeyDef, _ fn: Bool) -> KeyDef {
        guard fn, let f = k.fn else { return k }
        var e = k
        e.action = f
        e.label = nil
        e.toggle = false
        e.fn = nil
        return e
    }

    private func fnHint(_ k: KeyDef) -> String {
        guard let f = k.fn else { return "" }
        switch f {
        case .key(let c): return KeyCatalog.short(c)
        case .combo(let cs): return cs.map { KeyCatalog.short($0) }.joined(separator: "+")
        default:
            let cap = KeyDef(x: 0, y: 0, w: 1, h: 1, action: f).defaultCap()
            return cap.hasPrefix("sf:") ? "Fn" : cap
        }
    }

    private func legend(for k: KeyDef) -> (String, String, String) {
        if fnHeld > 0, k.fn != nil {
            return legend(for: effective(k, true))
        }
        if let l = k.label, !l.isEmpty { return (l, "", "") }
        guard case .key(let c) = k.action else { return (k.defaultCap(), "", "") }
        if c == KC.space {
            return (ConnectionManager.shared.pcState?.layoutName ?? "", "", "")
        }
        if KeyCatalog.printable.contains(c), let pair = legends.primary[c] {
            let (n, s) = pair
            var alt = ""
            if let sec = legends.secondary?[c] {
                let sn = sec.0
                if isLetter(sn) { alt = sn.uppercased() }
            }
            if isLetter(n) {
                let main = n.uppercased()
                return (main, "", alt == main ? "" : alt)
            }
            let shift = input.shiftActive
            let main = shift ? s : n
            let top = shift ? n : s
            return (main, top == main ? "" : top, alt)
        }
        return (KeyCatalog.cap(c), "", "")
    }

    func updateLegends() {
        legends = Legends.resolve(settings: settings, pc: ConnectionManager.shared.pcState)
        let pc = ConnectionManager.shared.pcState
        for k in layout.keys {
            guard let c = views[k.id] as? KeyCapView else { continue }
            let (main, top, alt) = legend(for: k)
            c.setLegend(main: main, top: top, alt: alt, fn: fnHeld > 0 ? "" : fnHint(k))
            c.fnLayer = fnHeld > 0 && k.fn != nil
            if case .key(let code) = k.action {
                switch code {
                case KC.caps: c.ledOn = pc?.caps ?? false
                case KC.numLock: c.ledOn = pc?.num ?? false
                case KC.scrollLock: c.ledOn = pc?.scroll ?? false
                default: c.ledOn = nil
                }
            }
        }
    }

    private func refreshStates() {
        for k in layout.keys {
            guard let c = views[k.id] as? KeyCapView else { continue }
            var pressed = (pressCount[k.id] ?? 0) > 0
            var latched = toggled.contains(k.id)
            if case .key(let code) = k.action, !latched {
                if input.latched[code] != nil {
                    latched = true
                } else if input.isHeld(code) {
                    // Held through another element (stick, the other Shift, a combo...).
                    pressed = true
                }
            }
            c.setState(pressed: pressed, latched: latched)
        }
    }

    private func sticksHold(_ code: UInt16) -> Bool {
        sticks.values.contains { $0.held.contains(code) }
    }

    // MARK: actions

    private func pressRaw(_ k: KeyDef) {
        switch k.action {
        case .key(let c): input.press(c)
        case .combo(let cs): cs.forEach { input.press($0) }
        case .mouse(let b): input.mouseDown(b)
        default: break
        }
    }

    private func releaseRaw(_ k: KeyDef) {
        switch k.action {
        case .key(let c): input.release(c)
        case .combo(let cs): cs.reversed().forEach { input.release($0) }
        case .mouse(let b): input.mouseUp(b)
        default: break
        }
    }

    private func keyDown(_ k: KeyDef) {
        pressCount[k.id, default: 0] += 1
        if settings.keySound { AudioServicesPlaySystemSound(1104) }
        if k.toggle {
            if toggled.contains(k.id) {
                toggled.remove(k.id)
                releaseRaw(k)
            } else {
                toggled.insert(k.id)
                pressRaw(k)
            }
            refreshStates()
            return
        }
        switch k.action {
        case .key(let c): input.touchDown(c)
        case .combo(let cs): cs.forEach { input.press($0) }
        case .mouse(let b): input.mouseDown(b)
        case .wheel(let d): input.scroll(vertical: Double(d) * 120, horizontal: 0)
        case .text(let s): input.text(s)
        case .special(let sp):
            switch sp {
            case .langSwitch: input.tapCombo(settings.langComboCodes)
            case .fn:
                fnHeld += 1
                updateLegends()
            case .releaseAll:
                releaseAllTouches()
                input.releaseAll()
            default: break
            }
        default: break
        }
        refreshStates()
    }

    private func keyUp(_ k: KeyDef) {
        if let n = pressCount[k.id] { pressCount[k.id] = n > 1 ? n - 1 : nil }
        if !k.toggle {
            switch k.action {
            case .key(let c): input.touchUp(c)
            case .combo(let cs): cs.reversed().forEach { input.release($0) }
            case .mouse(let b): input.mouseUp(b)
            case .special(let sp):
                if sp == .textPanel || sp == .nextLayout { onSpecial?(sp) }
                if sp == .fn {
                    fnHeld = max(0, fnHeld - 1)
                    updateLegends()
                }
            case .switchLayout(let id): onSwitchLayout?(id)
            default: break
            }
        }
        refreshStates()
    }

    /// Releases everything this view is holding (layout switch, app background, edit mode...).
    func releaseAllTouches() {
        for (_, b) in bindings {
            switch b {
            case .key(let id, let fn):
                if let k = keyDef(id) {
                    let e = effective(k, fn)
                    if !e.toggle { keyUp(e) }
                }
            case .zone(let id):
                zones[id]?.cancelAll()
                (views[id] as? ZoneView)?.active = false
            case .stick(let id):
                endStick(id)
            default: break
            }
        }
        bindings.removeAll()
        fnHeld = 0
        for id in toggled {
            if let k = keyDef(id) { releaseRaw(k) }
        }
        toggled.removeAll()
        pressCount.removeAll()
        refreshStates()
    }

    // MARK: stick

    private func updateStick(_ id: UUID, _ p: CGPoint) {
        guard var st = sticks[id], let k = keyDef(id), case .stick(let cfg) = k.action,
              let sv = views[id] as? StickView else { return }
        let r = max(sv.radius, 10)
        var off = CGPoint(x: p.x - st.center.x, y: p.y - st.center.y)
        var len = hypot(off.x, off.y)
        // Floating stick: drag the centre along when the finger goes far, so reversing is instant.
        let maxLen = r * 1.6
        if len > maxLen {
            let k2 = (len - maxLen) / len
            st.center = CGPoint(x: st.center.x + off.x * k2, y: st.center.y + off.y * k2)
            off = CGPoint(x: p.x - st.center.x, y: p.y - st.center.y)
            len = hypot(off.x, off.y)
        }
        let dist = len / r
        var want = Set<UInt16>()
        if dist > 0.28 {
            let nx = off.x / len, ny = off.y / len
            if ny < -0.38 { want.insert(cfg.up) }
            if ny > 0.38 { want.insert(cfg.down) }
            if nx < -0.38 { want.insert(cfg.left) }
            if nx > 0.38 { want.insert(cfg.right) }
            if let sprint = cfg.sprint, dist > 1.3, ny < -0.38 { want.insert(sprint) }
        }
        for c in st.held.subtracting(want) { input.release(c) }
        for c in want.subtracting(st.held) { input.press(c) }
        st.held = want
        sticks[id] = st
        let visual = len > r ? CGPoint(x: off.x / len * r, y: off.y / len * r) : off
        let c = convert(st.center, to: sv)
        sv.center0 = c
        sv.setKnob(center: c, offset: visual)
        refreshStates()
    }

    private func endStick(_ id: UUID) {
        if let st = sticks[id] {
            for c in st.held { input.release(c) }
        }
        sticks[id] = nil
        if let sv = views[id] as? StickView {
            sv.center0 = nil
            sv.setKnob(center: nil, offset: .zero)
        }
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { began(t, event) }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { moved(t, event) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { ended(t, cancelled: false) }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches { ended(t, cancelled: true) }
    }

    private func began(_ t: UITouch, _ event: UIEvent?) {
        let p = t.location(in: self)
        let key = ObjectIdentifier(t)
        if editing {
            beginEdit(t, p)
            return
        }
        guard let k = element(at: p) else {
            bindings[key] = .ignored
            return
        }
        switch k.action {
        case .trackpad, .mouseLook:
            zones[k.id]?.began(t, in: self)
            bindings[key] = .zone(k.id)
            (views[k.id] as? ZoneView)?.active = true
        case .stick:
            if sticks[k.id] != nil {
                bindings[key] = .ignored
                return
            }
            sticks[k.id] = StickState(center: p, held: [])
            bindings[key] = .stick(k.id)
            updateStick(k.id, p)
        default:
            let fn = fnHeld > 0 && k.fn != nil
            bindings[key] = .key(k.id, fn)
            keyDown(effective(k, fn))
        }
    }

    private func moved(_ t: UITouch, _ event: UIEvent?) {
        let key = ObjectIdentifier(t)
        guard let b = bindings[key] else { return }
        let p = t.location(in: self)
        switch b {
        case .key(let id, let fn):
            guard layout.glide, let k2 = element(at: p), k2.id != id, !k2.action.isZone, let k1 = keyDef(id) else { return }
            keyUp(effective(k1, fn))
            let fn2 = fnHeld > 0 && k2.fn != nil
            bindings[key] = .key(k2.id, fn2)
            keyDown(effective(k2, fn2))
        case .zone(let id):
            zones[id]?.moved(t, event: event, in: self)
        case .stick(let id):
            updateStick(id, p)
        case .edit(let op):
            applyEdit(op, p)
        case .ignored:
            break
        }
    }

    private func ended(_ t: UITouch, cancelled: Bool) {
        let key = ObjectIdentifier(t)
        guard let b = bindings.removeValue(forKey: key) else { return }
        switch b {
        case .key(let id, let fn):
            if let k = keyDef(id) { keyUp(effective(k, fn)) }
        case .zone(let id):
            zones[id]?.ended(t, cancelled: cancelled)
            if zones[id]?.isActive == false { (views[id] as? ZoneView)?.active = false }
        case .stick(let id):
            endStick(id)
            refreshStates()
        case .edit:
            onEdited?(layout)
        case .ignored:
            break
        }
    }

    // MARK: editing

    private func beginEdit(_ t: UITouch, _ p: CGPoint) {
        let key = ObjectIdentifier(t)
        let busy = bindings.values.contains { if case .edit = $0 { return true } else { return false } }
        if busy {
            bindings[key] = .ignored
            return
        }
        if let sel = selectedId, let f = views[sel]?.frame, hypot(p.x - f.maxX, p.y - f.maxY) < 32, let k = keyDef(sel) {
            bindings[key] = .edit(EditOp(id: sel, resize: true, start: p, orig: k))
            return
        }
        if let k = layout.keys.reversed().first(where: { cells[$0.id]?.contains(p) == true }) {
            selectedId = k.id
            onSelect?(k.id)
            updateSelection()
            bindings[key] = .edit(EditOp(id: k.id, resize: false, start: p, orig: k))
        } else {
            selectedId = nil
            onSelect?(nil)
            updateSelection()
            bindings[key] = .ignored
        }
    }

    private func applyEdit(_ op: EditOp, _ p: CGPoint) {
        guard let i = index[op.id], i < layout.keys.count else { return }
        let dx = Double((p.x - op.start.x) / ux)
        let dy = Double((p.y - op.start.y) / uy)
        func snap(_ v: Double) -> Double { (v * 4).rounded() / 4 }
        var k = layout.keys[i]
        if op.resize {
            k.w = min(max(0.5, snap(op.orig.w + dx)), max(0.5, layout.cols - k.x))
            k.h = min(max(0.5, snap(op.orig.h + dy)), max(0.5, layout.rows - k.y))
        } else {
            k.x = min(max(0, snap(op.orig.x + dx)), max(0, layout.cols - k.w))
            k.y = min(max(0, snap(op.orig.y + dy)), max(0, layout.rows - k.h))
        }
        if k != layout.keys[i] {
            layout.keys[i] = k
            setNeedsLayout()
            layoutIfNeeded()
        }
    }
}
