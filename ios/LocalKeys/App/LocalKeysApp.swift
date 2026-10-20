import SwiftUI
import UIKit

@main
struct LocalKeysApp: App {
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            MainView()
                .onAppear {
                    UIApplication.shared.isIdleTimerDisabled = true
                    ConnectionManager.shared.start()
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
}
