import SwiftUI

struct LockView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let lock = env.lock
        ZStack {
            Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
            Theme.background.opacity(0.85).ignoresSafeArea()
            VStack(spacing: 22) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(Theme.heroGradient)
                    .accessibilityHidden(true)
                Text(String(localized: "Vault Locked")).font(.title.bold())
                Text(String(localized: "Unlock with \(lock.biometryName) to continue."))
                    .foregroundStyle(.secondary)
                Button {
                    Task { await lock.unlock() }
                } label: {
                    Label(String(localized: "Unlock"), systemImage: lock.biometrySymbol)
                }
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 280)
                .disabled(lock.isAuthenticating)
                if let error = lock.lastError {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger).multilineTextAlignment(.center)
                }
            }
            .padding(32)
        }
        .task { await lock.unlock() }
    }
}

/// Shown while the app is inactive so the app switcher snapshot reveals nothing.
struct PrivacyCoverView: View {
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.heroGradient)
        }
        .accessibilityHidden(true)
    }
}
