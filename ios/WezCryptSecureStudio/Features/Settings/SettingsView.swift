import SwiftUI

struct SettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { StorageSettingsView() } label: { SettingsRow(symbol: "internaldrive", tint: .blue, title: String(localized: "Storage")) }
                    NavigationLink { EncryptionSettingsView() } label: { SettingsRow(symbol: "lock.shield", tint: .indigo, title: String(localized: "Encryption")) }
                    NavigationLink { SyncSettingsView() } label: { SettingsRow(symbol: "arrow.triangle.2.circlepath", tint: .teal, title: String(localized: "Synchronization")) }
                    NavigationLink { SecuritySettingsView() } label: { SettingsRow(symbol: env.lock.biometrySymbol, tint: .green, title: String(localized: "Security")) }
                }
                Section {
                    NavigationLink { AccountSettingsView() } label: { SettingsRow(symbol: "person.crop.circle", tint: .gray, title: String(localized: "Account")) }
                    NavigationLink { AboutView() } label: { SettingsRow(symbol: "info.circle", tint: .orange, title: String(localized: "About Developer")) }
                }
            }
            .navigationTitle(String(localized: "Settings"))
        }
    }
}

struct SettingsRow: View {
    let symbol: String
    let tint: Color
    let title: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(title)
        }
    }
}

// MARK: - Storage

struct StorageSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var account: AccountInfo?
    @State private var cacheBytes: Int64 = 0
    @State private var error: String?
    @State private var confirmClear = false

    var body: some View {
        List {
            Section(String(localized: "Vault on Server")) {
                if let account {
                    LabeledContent(String(localized: "Items"), value: "\(account.mediaCount)")
                    LabeledContent(String(localized: "Photos"), value: "\(account.photoCount)")
                    LabeledContent(String(localized: "Videos"), value: "\(account.videoCount)")
                    LabeledContent(String(localized: "Albums"), value: "\(account.albumCount)")
                    LabeledContent(String(localized: "Total Size"), value: Formatters.bytes(account.totalBytes))
                    LabeledContent(String(localized: "Max File Size"), value: Formatters.bytes(account.limits.maxFileSize))
                } else if let error {
                    Text(error).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            Section(String(localized: "This iPhone")) {
                LabeledContent(String(localized: "Free Space"), value: env.sync.deviceFreeSpace.map(Formatters.bytes) ?? "—")
                LabeledContent(String(localized: "Encrypted Thumbnail Cache"), value: Formatters.bytes(cacheBytes))
                Button(String(localized: "Clear Cache"), role: .destructive) { confirmClear = true }
            }
            Section {
                Text(String(localized: "The cache only holds encrypted thumbnails. Full photos and videos are streamed on demand and never stored decrypted."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "Storage"))
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(String(localized: "Clear the thumbnail cache?"), isPresented: $confirmClear, titleVisibility: .visible) {
            Button(String(localized: "Clear Cache"), role: .destructive) {
                Task {
                    await env.images.clear()
                    cacheBytes = await env.images.diskUsage()
                }
            }
        }
    }

    private func load() async {
        env.sync.refreshDeviceSpace()
        cacheBytes = await env.images.diskUsage()
        do {
            account = try await env.api.account()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Encryption

struct EncryptionSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var account: AccountInfo?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(String(localized: "Encrypted at rest on the server"), systemImage: "lock.shield.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.accent)
                    Text(String(localized: "Files travel over HTTPS (TLS 1.2+) and are encrypted on the server with AES-256-GCM using a random key per file. The server holds the master key, so this is server-side encryption — it is not end-to-end encryption."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section(String(localized: "Server")) {
                LabeledContent(String(localized: "Algorithm"), value: account?.encryption.algorithm ?? "AES-256-GCM")
                LabeledContent(String(localized: "Container"), value: account?.encryption.container ?? "—")
                LabeledContent(String(localized: "Keys"), value: account?.encryption.keyManagement ?? "—")
                LabeledContent(String(localized: "End-to-End"), value: (account?.encryption.endToEnd ?? false) ? String(localized: "Yes") : String(localized: "No"))
            }
            Section(String(localized: "This iPhone")) {
                LabeledContent(String(localized: "Device Identity"), value: env.deviceKeys.kind == .secureEnclave ? String(localized: "Secure Enclave key") : String(localized: "Keychain key"))
                LabeledContent(String(localized: "Session Tokens"), value: String(localized: "Keychain, this device only"))
                LabeledContent(String(localized: "Thumbnail Cache"), value: "WZC2 · AES-256-GCM")
            }
            Section(String(localized: "Client-Side Encryption")) {
                LabeledContent(String(localized: "Status"), value: String(localized: "Planned"))
                Text(String(localized: "A future mode will encrypt files on this iPhone before upload with a vault key that never leaves your devices, protected by a printable recovery key. Until it ships, the server can decrypt your files."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "Encryption"))
        .task { account = try? await env.api.account() }
    }
}

// MARK: - Synchronization

struct SyncSettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        List {
            Section {
                Picker(String(localized: "Upload Over"), selection: $settings.networkMode) {
                    ForEach(NetworkMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                Toggle(String(localized: "Respect Low Data Mode"), isOn: $settings.respectLowDataMode)
            } header: {
                Text(String(localized: "Network"))
            } footer: {
                Text(String(localized: "Cellular uploads of large videos can use a lot of data."))
            }
            Section(String(localized: "What to Sync")) {
                Toggle(String(localized: "Photos"), isOn: $settings.includePhotos)
                Toggle(String(localized: "Videos"), isOn: $settings.includeVideos)
            }
            Section {
                Stepper(value: $settings.maxConcurrentUploads, in: 1...4) {
                    LabeledContent(String(localized: "Parallel Uploads"), value: "\(settings.maxConcurrentUploads)")
                }
            } footer: {
                Text(String(localized: "More parallel uploads can be faster on good connections but use more battery."))
            }
            Section {
                Toggle(String(localized: "Sync New Items on Launch"), isOn: $settings.autoSyncOnLaunch)
                Toggle(String(localized: "Background Sync"), isOn: $settings.backgroundSyncEnabled)
                if settings.backgroundSyncEnabled {
                    Toggle(String(localized: "Only While Charging"), isOn: $settings.backgroundRequiresPower)
                }
            } header: {
                Text(String(localized: "Automatic"))
            } footer: {
                Text(String(localized: "iOS decides when background sync runs (usually while charging on Wi‑Fi) and limits how long it may run. Uploads always resume where they stopped."))
            }
            Section {
                Button(String(localized: "Rescan Entire Library")) { env.sync.syncAll() }
            } footer: {
                Text(String(localized: "Re-checks every photo and video. Items already in the vault are detected by their SHA-256 and skipped."))
            }
        }
        .navigationTitle(String(localized: "Synchronization"))
        .onChange(of: env.settings.syncPolicy) { _, _ in env.sync.policyChanged() }
        .onChange(of: env.settings.backgroundSyncEnabled) { _, enabled in
            if enabled {
                BackgroundSyncScheduler.schedule(requiresExternalPower: env.settings.backgroundRequiresPower)
            } else {
                BackgroundSyncScheduler.cancelAll()
            }
        }
    }
}

// MARK: - Security

struct SecuritySettingsView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        @Bindable var settings = env.settings
        List {
            Section {
                Toggle(isOn: Binding(
                    get: { settings.appLockEnabled },
                    set: { newValue in
                        Task {
                            let reason = newValue ? String(localized: "Turn on app lock") : String(localized: "Turn off app lock")
                            if await env.lock.confirmOwner(reason: reason) {
                                settings.appLockEnabled = newValue
                            }
                        }
                    }
                )) {
                    Label(String(localized: "Lock with \(env.lock.biometryName)"), systemImage: env.lock.biometrySymbol)
                }
                .disabled(!env.lock.canUseDeviceAuthentication)
                if settings.appLockEnabled {
                    Picker(String(localized: "Require Unlock"), selection: $settings.lockGrace) {
                        ForEach(LockGrace.allCases) { grace in Text(grace.title).tag(grace) }
                    }
                }
                Toggle(String(localized: "Hide Content in App Switcher"), isOn: $settings.privacyCoverEnabled)
            } footer: {
                if !env.lock.canUseDeviceAuthentication {
                    Text(String(localized: "Set a passcode on this iPhone to use app lock."))
                }
            }
            Section {
                NavigationLink(String(localized: "Linked Devices")) { DevicesView() }
            } footer: {
                Text(String(localized: "Revoke any device you no longer use. A revoked device loses access immediately."))
            }
        }
        .navigationTitle(String(localized: "Security"))
    }
}

struct DevicesView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var devices: [DeviceInfo] = []
    @State private var error: String?
    @State private var revoking: DeviceInfo?

    var body: some View {
        List {
            if let error {
                Text(error).foregroundStyle(.secondary)
            }
            ForEach(devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(device.name).font(.headline)
                        if device.isCurrent {
                            Text(String(localized: "This iPhone"))
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.15), in: Capsule())
                                .foregroundStyle(Theme.accent)
                        }
                    }
                    Text("\(device.model) · \(device.systemVersion)").font(.caption).foregroundStyle(.secondary)
                    Text(String(localized: "Last active \(device.lastSeenAt.formatted(.relative(presentation: .named)))")).font(.caption).foregroundStyle(.secondary)
                }
                .swipeActions {
                    Button(String(localized: "Revoke"), role: .destructive) { revoking = device }
                }
            }
        }
        .navigationTitle(String(localized: "Linked Devices"))
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog(
            String(localized: "Revoke this device?"),
            isPresented: Binding(get: { revoking != nil }, set: { if !$0 { revoking = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "Revoke Access"), role: .destructive) {
                if let device = revoking {
                    Task {
                        do {
                            try await env.auth.revoke(device)
                            await load()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                }
                revoking = nil
            }
        } message: {
            Text(revoking?.isCurrent == true ? String(localized: "This iPhone will be signed out.") : String(localized: "The device will need to be linked again."))
        }
    }

    private func load() async {
        do {
            devices = try await env.auth.devices()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Account

struct AccountSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var account: AccountInfo?
    @State private var confirmSignOut = false

    var body: some View {
        List {
            Section(String(localized: "Vault")) {
                LabeledContent(String(localized: "Server"), value: AppConfig.apiBaseURL.host ?? "")
                if let account {
                    LabeledContent(String(localized: "Telegram Account"), value: Self.mask(account.telegramUserId))
                    LabeledContent(String(localized: "Device ID"), value: String(account.deviceId.prefix(8)) + "…")
                }
            }
            Section {
                Button(String(localized: "Sign Out of This iPhone"), role: .destructive) { confirmSignOut = true }
            } footer: {
                Text(String(localized: "Signing out revokes this device, deletes its keys, session and encrypted cache. Your vault and the photos on this iPhone are not affected."))
            }
        }
        .navigationTitle(String(localized: "Account"))
        .task { account = try? await env.api.account() }
        .confirmationDialog(String(localized: "Sign out of this iPhone?"), isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button(String(localized: "Sign Out"), role: .destructive) { Task { await env.auth.signOut() } }
        }
    }

    static func mask(_ id: Int64) -> String {
        let text = String(id)
        guard text.count > 4 else { return "••••" }
        return String(repeating: "•", count: text.count - 4) + text.suffix(4)
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "lock.shield.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(Theme.heroGradient)
                    Text(AppConfig.appName).font(.title2.bold())
                    Text(String(localized: "Version \(AppConfig.appVersion)")).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section(String(localized: "Developer")) {
                LabeledContent(String(localized: "Developer"), value: AppConfig.developerName)
                Link(destination: AppConfig.developerWebsite) {
                    LabeledContent(String(localized: "Website"), value: "wezcrypt.com")
                }
                LabeledContent(String(localized: "Server"), value: AppConfig.apiBaseURL.host ?? "")
            }
            Section {
                Text(String(localized: "A private, encrypted photo and video vault. Built natively with SwiftUI, PhotoKit, AVFoundation and CryptoKit."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(String(localized: "About Developer"))
    }
}
