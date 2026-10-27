import Foundation
import Combine

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    // Appearance
    @Published var themeId: String { didSet { d.set(themeId, forKey: "themeId") } }
    @Published var keyGap: Double { didSet { d.set(keyGap, forKey: "keyGap") } }
    @Published var showTopBar: Bool { didSet { d.set(showTopBar, forKey: "showTopBar") } }

    // Keyboard
    @Published var keySound: Bool { didSet { d.set(keySound, forKey: "keySound") } }
    @Published var stickyModifiers: Bool { didSet { d.set(stickyModifiers, forKey: "stickyModifiers") } }
    /// auto (from the PC) | en | ru | ua
    @Published var legendMode: String { didSet { d.set(legendMode, forKey: "legendMode") } }
    @Published var bilingual: Bool { didSet { d.set(bilingual, forKey: "bilingual") } }
    /// Second language printed on keycaps while the PC is in English: ru | ua | none
    @Published var secondLang: String { didSet { d.set(secondLang, forKey: "secondLang") } }
    /// Size of the second-language legend relative to the main one (0.4...1).
    @Published var altScale: Double { didSet { d.set(altScale, forKey: "altScale") } }
    /// Also show the second language's Shift symbols on digit / punctuation keys.
    @Published var altShifted: Bool { didSet { d.set(altShifted, forKey: "altShifted") } }
    /// winSpace | altShift | ctrlShift
    @Published var langCombo: String { didSet { d.set(langCombo, forKey: "langCombo") } }

    // Pointer
    @Published var pointerSpeed: Double { didSet { d.set(pointerSpeed, forKey: "pointerSpeed") } }
    @Published var pointerAccel: Double { didSet { d.set(pointerAccel, forKey: "pointerAccel") } }
    @Published var scrollSpeed: Double { didSet { d.set(scrollSpeed, forKey: "scrollSpeed") } }
    @Published var naturalScroll: Bool { didSet { d.set(naturalScroll, forKey: "naturalScroll") } }
    @Published var scrollMomentum: Bool { didSet { d.set(scrollMomentum, forKey: "scrollMomentum") } }
    @Published var tapToClick: Bool { didSet { d.set(tapToClick, forKey: "tapToClick") } }
    @Published var lookSpeed: Double { didSet { d.set(lookSpeed, forKey: "lookSpeed") } }
    @Published var invertLookY: Bool { didSet { d.set(invertLookY, forKey: "invertLookY") } }

    // Joystick
    /// The flight stick follows the iPad's tilt (otherwise only a finger moves it).
    @Published var stickTilt: Bool { didSet { d.set(stickTilt, forKey: "stickTilt") } }
    /// Tilt angle (degrees) for a full deflection.
    @Published var tiltRange: Double { didSet { d.set(tiltRange, forKey: "tiltRange") } }
    /// Tilt dead zone around the centre (fraction of full deflection).
    @Published var tiltDeadzone: Double { didSet { d.set(tiltDeadzone, forKey: "tiltDeadzone") } }

    // Connection
    @Published var wifiEnabled: Bool { didSet { d.set(wifiEnabled, forKey: "wifiEnabled") } }
    @Published var usbEnabled: Bool { didSet { d.set(usbEnabled, forKey: "usbEnabled") } }
    @Published var manualHost: String { didSet { d.set(manualHost, forKey: "manualHost") } }
    @Published var preferredPC: String { didSet { d.set(preferredPC, forKey: "preferredPC") } }
    @Published var deviceName: String { didSet { d.set(deviceName, forKey: "deviceName") } }

    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }

    /// Per-layout placement: layout id -> [vertical position 0 (top)...1 (bottom), size 0.5...1].
    @Published var placements: [String: [Double]] { didSet { d.set(placements, forKey: "placements") } }

    func vpos(_ layoutId: String) -> Double { placements[layoutId]?.first ?? 0.5 }
    func scale(_ layoutId: String) -> Double {
        guard let p = placements[layoutId], p.count > 1 else { return 1 }
        return p[1]
    }
    func setPlacement(_ layoutId: String, vpos: Double? = nil, scale: Double? = nil) {
        let v = min(max(vpos ?? self.vpos(layoutId), 0), 1)
        let s = min(max(scale ?? self.scale(layoutId), 0.5), 1)
        placements[layoutId] = [v, s]
    }

    let deviceId: String

    /// LAN addresses the PC reported (also learned over USB): fallback when Bonjour fails.
    var knownHosts: [String] {
        get { d.stringArray(forKey: "knownHosts") ?? [] }
        set { d.set(newValue, forKey: "knownHosts") }
    }

    var lastHost: String {
        get { d.string(forKey: "lastHost") ?? "" }
        set { d.set(newValue, forKey: "lastHost") }
    }

    func token(for pcId: String) -> String? { (d.dictionary(forKey: "tokens") as? [String: String])?[pcId] }

    func setToken(_ token: String?, for pcId: String) {
        var all = (d.dictionary(forKey: "tokens") as? [String: String]) ?? [:]
        all[pcId] = token
        d.set(all, forKey: "tokens")
    }

    func forgetAllPairings() { d.removeObject(forKey: "tokens") }

    private init() {
        let ud = UserDefaults.standard
        func v<T>(_ key: String, _ def: T) -> T { (ud.object(forKey: key) as? T) ?? def }
        themeId = v("themeId", "midnight")
        keyGap = v("keyGap", 5.0)
        showTopBar = v("showTopBar", true)
        keySound = v("keySound", false)
        stickyModifiers = v("stickyModifiers", false)
        legendMode = v("legendMode", "auto")
        bilingual = v("bilingual", true)
        secondLang = v("secondLang", "ru")
        altScale = v("altScale", 0.72)
        altShifted = v("altShifted", true)
        langCombo = v("langCombo", "winSpace")
        pointerSpeed = v("pointerSpeed", 1.0)
        pointerAccel = v("pointerAccel", 0.7)
        scrollSpeed = v("scrollSpeed", 1.0)
        naturalScroll = v("naturalScroll", true)
        scrollMomentum = v("scrollMomentum", true)
        tapToClick = v("tapToClick", true)
        lookSpeed = v("lookSpeed", 1.0)
        invertLookY = v("invertLookY", false)
        stickTilt = v("stickTilt", true)
        tiltRange = v("tiltRange", 25.0)
        tiltDeadzone = v("tiltDeadzone", 0.03)
        wifiEnabled = v("wifiEnabled", true)
        usbEnabled = v("usbEnabled", true)
        manualHost = v("manualHost", "")
        preferredPC = v("preferredPC", "")
        deviceName = v("deviceName", "iPad")
        onboardingDone = v("onboardingDone", false)
        placements = v("placements", [String: [Double]]())
        if let id = ud.string(forKey: "deviceId") {
            deviceId = id
        } else {
            let id = UUID().uuidString
            ud.set(id, forKey: "deviceId")
            deviceId = id
        }
    }

    var langComboCodes: [UInt16] {
        switch langCombo {
        case "altShift": return [KC.lalt, KC.lshift]
        case "ctrlShift": return [KC.lctrl, KC.lshift]
        default: return [KC.lwin, KC.space]
        }
    }
}
