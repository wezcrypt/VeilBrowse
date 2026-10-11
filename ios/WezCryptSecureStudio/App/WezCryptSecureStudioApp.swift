import BackgroundTasks
import SwiftUI
import UIKit

@main
struct WezCryptSecureStudioApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let environment = AppEnvironment.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .tint(Theme.accent)
                .task { await environment.bootstrap() }
        }
        .onChange(of: scenePhase) { _, phase in
            environment.handleScenePhase(phase)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // BGTask handlers must be registered before launch completes.
        BackgroundSyncScheduler.register { task in
            let box = UncheckedSendable(task)
            Task { @MainActor in
                let environment = AppEnvironment.shared
                guard await environment.credentials.current() != nil, environment.photos.hasAccess else {
                    box.value.setTaskCompleted(success: true)
                    return
                }
                if environment.settings.backgroundSyncEnabled {
                    BackgroundSyncScheduler.schedule(requiresExternalPower: environment.settings.backgroundRequiresPower)
                }
                environment.sync.runBackgroundPass(box.value)
            }
        }
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == AppConfig.backgroundUploadSessionIdentifier else {
            completionHandler()
            return
        }
        let handler = UncheckedSendable(completionHandler)
        MainActor.assumeIsolated {
            AppEnvironment.shared.transport.setBackgroundCompletionHandler { handler.value() }
        }
    }
}
