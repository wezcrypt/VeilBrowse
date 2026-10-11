import BackgroundTasks
import SwiftUI
import UIKit

@main
struct WezCryptSecureStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let model = AppModel.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
                .task { await model.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in model.handleScenePhase(phase) }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundScheduler.register { task in
            let box = UncheckedSendable(task)
            Task { @MainActor in
                let model = AppModel.shared
                guard model.stage == .ready else {
                    box.value.setTaskCompleted(success: true)
                    return
                }
                await model.engine.configure(api: model.api)
                model.sync.handle(box.value)
            }
        }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == AppConfig.backgroundSessionIdentifier else {
            completionHandler()
            return
        }
        let handler = UncheckedSendable(completionHandler)
        AppModel.shared.transport.setBackgroundCompletionHandler { handler.value() }
    }
}
