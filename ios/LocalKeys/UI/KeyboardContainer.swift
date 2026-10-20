import SwiftUI
import UIKit

final class KeyboardViewController: UIViewController {
    let keyboard = KeyboardView()

    override func loadView() { view = keyboard }

    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var prefersStatusBarHidden: Bool { true }
}

struct KeyboardContainer: UIViewControllerRepresentable {
    var layout: KBLayout
    var theme: KTheme
    var gap: Double
    var editing: Bool
    var selectedId: UUID?
    var vpos: Double
    var scale: Double
    var onSelect: (UUID?) -> Void
    var onEdited: (KBLayout) -> Void
    var onSpecial: (SpecialAction) -> Void
    var onSwitchLayout: (String) -> Void
    var onEditTap: (UUID) -> Void = { _ in }

    func makeUIViewController(context: Context) -> KeyboardViewController {
        KeyboardViewController()
    }

    func updateUIViewController(_ vc: KeyboardViewController, context: Context) {
        let kb = vc.keyboard
        kb.onSelect = onSelect
        kb.onEdited = onEdited
        kb.onSpecial = onSpecial
        kb.onSwitchLayout = onSwitchLayout
        kb.onEditTap = onEditTap
        kb.apply(layout: layout, theme: theme, gap: CGFloat(gap), editing: editing,
                 selectedId: selectedId, vpos: CGFloat(vpos), scale: CGFloat(scale))
    }
}
