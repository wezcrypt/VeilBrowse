import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.stage == .ready {
                MainTabView()
            } else {
                OnboardingFlow()
            }
            if model.lock.isLocked {
                LockView().zIndex(2).transition(.opacity)
            } else if model.lock.isObscured {
                PrivacyCover().zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: model.lock.isLocked)
        .animation(.easeInOut(duration: 0.25), value: model.stage)
    }
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            DashboardView().tabItem { Label(String(localized: "Dashboard"), systemImage: "gauge.with.dots.needle.67percent") }
            LibraryView().tabItem { Label(String(localized: "Library"), systemImage: "photo.on.rectangle.angled") }
            TransfersView().tabItem { Label(String(localized: "Transfers"), systemImage: "arrow.up.arrow.down.circle") }
                .badge(model.sync.snapshot.counts.failed)
            SettingsView().tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
        }
    }
}

struct LockView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let lock = model.lock
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "lock.shield.fill").font(.system(size: 64)).foregroundStyle(Theme.heroGradient)
                Text(String(localized: "Locked")).font(.title.bold())
                Button { Task { await lock.unlock() } } label: { Label(String(localized: "Unlock"), systemImage: lock.biometrySymbol) }
                    .buttonStyle(PrimaryButtonStyle()).frame(maxWidth: 260)
                if let error = lock.lastError { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
            }
            .padding(32)
        }
        .task { await lock.unlock() }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Image(systemName: "lock.shield.fill").font(.system(size: 56)).foregroundStyle(Theme.heroGradient)
        }
        .accessibilityHidden(true)
    }
}
