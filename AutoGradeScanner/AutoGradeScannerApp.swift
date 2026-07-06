import SwiftUI

@main
struct AutoGradeScannerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .tint(AG.brand)
        }
    }
}
