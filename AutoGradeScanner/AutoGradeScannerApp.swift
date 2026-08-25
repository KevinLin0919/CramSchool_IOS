import SwiftUI

@main
struct AutoGradeScannerApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        DemoSelfTest.runIfRequested()
        RecognitionSelfTest.runIfRequested()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.light)
                .tint(AG.brand)
        }
        .onChange(of: scenePhase) { _, phase in
            // Coming back to the app is the one moment a device that graded a
            // stack on a dead network is likely to have one again. The queue
            // decides for itself whether there is anything to do; iOS suspends
            // whatever was in flight when the app left, and since every upload
            // is idempotent on a UUID the device minted, resuming is just
            // trying again.
            if phase == .active { UploadQueue.shared.drain() }
        }
    }
}
