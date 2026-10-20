import SwiftUI
import UIKit

@main
struct LocalKeysApp: App {
    @Environment(\.scenePhase) private var phase

    init() {
        // CI screenshot mode (simulator): LK_SCREENSHOT=1, LK_LAYOUT=<layout id>, LK_THEME=<theme id>.
        let env = ProcessInfo.processInfo.environment
        if env["LK_SCREENSHOT"] != nil {
            AppSettings.shared.onboardingDone = true
            if let l = env["LK_LAYOUT"] { LayoutStore.shared.currentId = l }
            if let t = env["LK_THEME"] { AppSettings.shared.themeId = t }
            if let v = env["LK_VPOS"], let d = Double(v) {
                AppSettings.shared.setPlacement(LayoutStore.shared.currentId, vpos: d, scale: 0.85)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    ConnectionManager.shared.start()
                    if ProcessInfo.processInfo.environment["LK_LANDSCAPE"] != nil {
                        forceLandscape()
                    }
                }
                .onChange(of: phase) { newPhase in
                    switch newPhase {
                    case .active:
                        UIApplication.shared.isIdleTimerDisabled = true
                        ConnectionManager.shared.start()
                    case .background:
                        ConnectionManager.shared.stop()
                    default:
                        break
                    }
                }
        }
    }

    private func forceLandscape() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
            NSLog("LocalKeys: geometry update failed: \(error)")
        }
    }
}
