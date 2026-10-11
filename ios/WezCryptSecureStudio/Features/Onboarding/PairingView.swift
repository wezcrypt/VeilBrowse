import SwiftUI

/// Links this iPhone to the vault through the existing Telegram bot.
struct PairingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        let auth = env.auth
        ScrollView {
            VStack(spacing: 28) {
                header
                switch auth.state {
                case .pairing(let ticket):
                    ticketCard(ticket)
                default:
                    introCard
                }
                if let error = auth.lastError {
                    ErrorBanner(message: error)
                }
                securityNotes
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private var header: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(Theme.heroGradient)
                    .frame(width: 92, height: 92)
                    .shadow(color: Theme.accent.opacity(0.4), radius: 20, y: 10)
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            Text(AppConfig.appName)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
            Text(String(localized: "Your private, encrypted photo and video vault."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 32)
    }

    private var introCard: some View {
        GlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Link this iPhone"))
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                step(1, String(localized: "Generate a one-time pairing code."))
                step(2, String(localized: "Send it to your WezCrypt bot in Telegram."))
                step(3, String(localized: "This screen unlocks automatically."))
                Button {
                    Task { await env.auth.startPairing() }
                } label: {
                    if env.auth.isWorking {
                        ProgressView().tint(.white)
                    } else {
                        Text(String(localized: "Generate Pairing Code"))
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(env.auth.isWorking)
                .accessibilityIdentifier("generatePairingCode")
            }
        }
    }

    private func ticketCard(_ ticket: AuthManager.PairingTicket) -> some View {
        GlassCard(padding: 20) {
            VStack(spacing: 18) {
                Text(String(localized: "Your pairing code"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(ticket.code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .tracking(4)
                    .textSelection(.enabled)
                    .accessibilityLabel(ticket.code.map { String($0) }.joined(separator: " "))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, ticket.expiresAt.timeIntervalSince(context.date))
                    Text(String(localized: "Expires in \(Formatters.duration(remaining))"))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(remaining < 60 ? Theme.warning : .secondary)
                }
                if let link = ticket.telegramLink {
                    Button {
                        openURL(link)
                    } label: {
                        Label(String(localized: "Open Telegram"), systemImage: "paperplane.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Button {
                    UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: "/pair \(ticket.code)"]], options: [.expirationDate: Date().addingTimeInterval(300), .localOnly: true])
                    copied = true
                } label: {
                    Label(copied ? String(localized: "Copied") : String(localized: "Copy /pair Command"), systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SecondaryButtonStyle())
                Text(ticket.botUsername.map { String(localized: "Send /pair \(ticket.code) to @\($0).") } ?? String(localized: "Send /pair \(ticket.code) to your WezCrypt bot."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 8) {
                    ProgressView()
                    Text(String(localized: "Waiting for approval…")).font(.footnote).foregroundStyle(.secondary)
                }
                Button(String(localized: "Cancel")) { env.auth.cancelPairing() }
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.footnote.bold())
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Theme.accent, in: Circle())
            Text(text).font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }

    private var securityNotes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(String(localized: "The code is single-use and expires in minutes."), systemImage: "timer")
            Label(String(localized: "This iPhone gets its own key in the Secure Enclave."), systemImage: "cpu")
            Label(String(localized: "No passwords, bot tokens or encryption keys are stored in the app."), systemImage: "key.slash")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
