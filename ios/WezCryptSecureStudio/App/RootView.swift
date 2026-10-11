import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        ZStack {
            switch env.auth.state {
            case .unknown:
                ZStack {
                    Theme.background.ignoresSafeArea()
                    ProgressView()
                }
            case .signedOut, .pairing:
                PairingView()
                    .transition(.opacity)
            case .signedIn:
                MainTabView()
                    .transition(.opacity)
            }

            if env.lock.isLocked {
                LockView()
                    .transition(.opacity)
                    .zIndex(2)
            } else if env.lock.isObscured {
                PrivacyCoverView()
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: env.auth.state)
        .animation(.easeInOut(duration: 0.2), value: env.lock.isLocked)
        .onChange(of: env.auth.isSignedIn) { wasSignedIn, isSignedIn in
            if isSignedIn && !wasSignedIn {
                Task { await env.signedInStartup() }
            }
        }
    }
}

struct MainTabView: View {
    enum Tab: Hashable {
        case library, albums, search, transfers, settings
    }

    @Environment(AppEnvironment.self) private var env
    @State private var tab: Tab = .library

    var body: some View {
        TabView(selection: $tab) {
            LibraryView()
                .tabItem { Label(String(localized: "Library"), systemImage: "photo.on.rectangle.angled") }
                .tag(Tab.library)
            AlbumsView()
                .tabItem { Label(String(localized: "Albums"), systemImage: "rectangle.stack.fill") }
                .tag(Tab.albums)
            SearchView(api: env.api)
                .tabItem { Label(String(localized: "Search"), systemImage: "magnifyingglass") }
                .tag(Tab.search)
            TransfersView()
                .tabItem { Label(String(localized: "Transfers"), systemImage: "arrow.up.arrow.down.circle") }
                .badge(env.sync.snapshot.counts.failed > 0 ? Text("\(env.sync.snapshot.counts.failed)") : nil)
                .tag(Tab.transfers)
            SettingsView()
                .tabItem { Label(String(localized: "Settings"), systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .overlay(alignment: .top) {
            if let warning = env.startupWarning {
                ErrorBanner(message: warning).padding()
            }
        }
    }
}
