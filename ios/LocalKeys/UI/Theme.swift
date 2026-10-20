import UIKit
import SwiftUI

struct KTheme {
    let id: String
    let name: String
    let bg: UIColor
    let bar: UIColor
    let key: UIColor
    let keyMod: UIColor
    let keyAccent: UIColor
    let keyDanger: UIColor
    let pressed: UIColor
    let latched: UIColor
    let text: UIColor
    let textDim: UIColor
    let border: UIColor
    let zone: UIColor
    let zoneBorder: UIColor
    let accent: UIColor
    let shadow: Bool

    static let midnight = KTheme(
        id: "midnight", name: "Полночь",
        bg: UIColor(red: 0.055, green: 0.063, blue: 0.086, alpha: 1),
        bar: UIColor(red: 0.075, green: 0.083, blue: 0.11, alpha: 1),
        key: UIColor(red: 0.145, green: 0.157, blue: 0.2, alpha: 1),
        keyMod: UIColor(red: 0.105, green: 0.115, blue: 0.15, alpha: 1),
        keyAccent: UIColor(red: 0.30, green: 0.40, blue: 0.98, alpha: 1),
        keyDanger: UIColor(red: 0.62, green: 0.18, blue: 0.22, alpha: 1),
        pressed: UIColor(red: 0.42, green: 0.55, blue: 1.0, alpha: 1),
        latched: UIColor(red: 0.95, green: 0.68, blue: 0.25, alpha: 1),
        text: UIColor(white: 0.95, alpha: 1),
        textDim: UIColor(white: 0.62, alpha: 1),
        border: UIColor(white: 1, alpha: 0.06),
        zone: UIColor(red: 0.09, green: 0.10, blue: 0.135, alpha: 1),
        zoneBorder: UIColor(white: 1, alpha: 0.08),
        accent: UIColor(red: 0.45, green: 0.58, blue: 1.0, alpha: 1),
        shadow: true)

    static let graphite = KTheme(
        id: "graphite", name: "Графит",
        bg: UIColor(white: 0.10, alpha: 1),
        bar: UIColor(white: 0.12, alpha: 1),
        key: UIColor(white: 0.21, alpha: 1),
        keyMod: UIColor(white: 0.155, alpha: 1),
        keyAccent: UIColor(red: 0.16, green: 0.62, blue: 0.48, alpha: 1),
        keyDanger: UIColor(red: 0.62, green: 0.2, blue: 0.2, alpha: 1),
        pressed: UIColor(red: 0.25, green: 0.8, blue: 0.62, alpha: 1),
        latched: UIColor(red: 0.95, green: 0.7, blue: 0.3, alpha: 1),
        text: UIColor(white: 0.93, alpha: 1),
        textDim: UIColor(white: 0.6, alpha: 1),
        border: UIColor(white: 1, alpha: 0.05),
        zone: UIColor(white: 0.14, alpha: 1),
        zoneBorder: UIColor(white: 1, alpha: 0.07),
        accent: UIColor(red: 0.3, green: 0.85, blue: 0.65, alpha: 1),
        shadow: true)

    static let light = KTheme(
        id: "light", name: "Светлая",
        bg: UIColor(red: 0.84, green: 0.85, blue: 0.88, alpha: 1),
        bar: UIColor(red: 0.88, green: 0.89, blue: 0.92, alpha: 1),
        key: UIColor.white,
        keyMod: UIColor(red: 0.74, green: 0.76, blue: 0.8, alpha: 1),
        keyAccent: UIColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1),
        keyDanger: UIColor(red: 0.9, green: 0.35, blue: 0.35, alpha: 1),
        pressed: UIColor(red: 0.55, green: 0.7, blue: 1.0, alpha: 1),
        latched: UIColor(red: 1.0, green: 0.75, blue: 0.3, alpha: 1),
        text: UIColor(white: 0.08, alpha: 1),
        textDim: UIColor(white: 0.4, alpha: 1),
        border: UIColor(white: 0, alpha: 0.08),
        zone: UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1),
        zoneBorder: UIColor(white: 0, alpha: 0.1),
        accent: UIColor(red: 0.2, green: 0.45, blue: 0.95, alpha: 1),
        shadow: true)

    static let neon = KTheme(
        id: "neon", name: "Неон",
        bg: UIColor(red: 0.03, green: 0.02, blue: 0.06, alpha: 1),
        bar: UIColor(red: 0.05, green: 0.03, blue: 0.09, alpha: 1),
        key: UIColor(red: 0.09, green: 0.06, blue: 0.15, alpha: 1),
        keyMod: UIColor(red: 0.06, green: 0.04, blue: 0.11, alpha: 1),
        keyAccent: UIColor(red: 0.85, green: 0.15, blue: 0.75, alpha: 1),
        keyDanger: UIColor(red: 0.8, green: 0.1, blue: 0.25, alpha: 1),
        pressed: UIColor(red: 0.0, green: 0.95, blue: 0.95, alpha: 1),
        latched: UIColor(red: 1.0, green: 0.85, blue: 0.1, alpha: 1),
        text: UIColor(red: 0.85, green: 0.95, blue: 1.0, alpha: 1),
        textDim: UIColor(red: 0.6, green: 0.5, blue: 0.85, alpha: 1),
        border: UIColor(red: 0.6, green: 0.3, blue: 1.0, alpha: 0.35),
        zone: UIColor(red: 0.05, green: 0.03, blue: 0.1, alpha: 1),
        zoneBorder: UIColor(red: 0.0, green: 0.9, blue: 0.9, alpha: 0.3),
        accent: UIColor(red: 0.0, green: 0.95, blue: 0.95, alpha: 1),
        shadow: false)

    static let all: [KTheme] = [midnight, graphite, light, neon]

    static func byId(_ id: String) -> KTheme { all.first { $0.id == id } ?? midnight }

    var isLight: Bool { id == "light" }
}
