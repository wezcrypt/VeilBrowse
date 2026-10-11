import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { SyncSettingsView() } label: { Label(String(localized: "Sync Settings"), systemImage: "arrow.triangle.2.circlepath") }
                    NavigationLink { SecuritySettingsView() } label: { Label(String(localized: "Security"), systemImage: "lock.shield") }
                    NavigationLink { ServerSetupView() } label: { Label(String(localized: "Server"), systemImage: "server.rack") }
                }
                Section {
                    NavigationLink { AboutView() } label: { Label(String(localized: "About"), systemImage: "info.circle") }
                }
            }
            .navigationTitle(String(localized: "Settings"))
        }
    }
}

struct SyncSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var sync = model.sync
        List {
            Section {
                Toggle(String(localized: "Wi‑Fi Only"), isOn: $sync.settings.wifiOnly)
                Toggle(String(localized: "Allow Cellular Data"), isOn: $sync.settings.allowCellular).disabled(sync.settings.wifiOnly)
                Toggle(String(localized: "Respect Low Data Mode"), isOn: $sync.settings.respectLowDataMode)
            } header: { Text(String(localized: "Network")) }
            Section {
                Toggle(String(localized: "Only While Charging"), isOn: $sync.settings.chargingOnly)
                Picker(String(localized: "In Low Power Mode"), selection: $sync.settings.lowPowerBehavior) {
                    ForEach(LowPowerBehavior.allCases) { Text($0.title).tag($0) }
                }
            } header: { Text(String(localized: "Battery")) } footer: {
                Text(String(localized: "Uploads also slow down automatically when the iPhone gets warm or the battery is below 20%."))
            }
            Section {
                Stepper(value: $sync.settings.maxConcurrency, in: 1...8) {
                    LabeledContent(String(localized: "Parallel Uploads"), value: "\(sync.settings.maxConcurrency)")
                }
                Picker(String(localized: "Chunk Size"), selection: $sync.settings.chunkSizeMB) {
                    Text("8 MB").tag(8)
                    Text("16 MB").tag(16)
                    Text("32 MB").tag(32)
                }
            } header: { Text(String(localized: "Performance")) }
            Section(String(localized: "Content")) {
                Toggle(String(localized: "Photos & Live Photos"), isOn: $sync.settings.includePhotos)
                Toggle(String(localized: "Videos"), isOn: $sync.settings.includeVideos)
                LabeledContent(String(localized: "Quality"), value: String(localized: "Original (no re-encoding)"))
            }
            Section {
                Toggle(String(localized: "Background Backup"), isOn: $sync.settings.backgroundSync)
            } footer: {
                Text(String(localized: "iOS decides when background work runs (usually overnight while charging) and for how long. Uploads already started keep going while the app is suspended. If you force-quit the app from the app switcher, iOS stops its background transfers until you open it again."))
            }
            Section {
                Button(String(localized: "Rescan Entire Library")) { sync.start(fullScan: true) }
            }
        }
        .navigationTitle(String(localized: "Sync Settings"))
    }
}

struct SecuritySettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var revealedKey: String?
    @State private var confirmDisconnect = false
    @State private var forgetKey = false

    var body: some View {
        @Bindable var security = model.security
        List {
            Section {
                Toggle(isOn: Binding(get: { security.appLockEnabled }, set: { value in
                    Task { if await model.lock.confirmOwner(reason: String(localized: "Change app lock")) { security.appLockEnabled = value } }
                })) { Label(String(localized: "Lock with \(model.lock.biometryName)"), systemImage: model.lock.biometrySymbol) }
                .disabled(!model.lock.canUseDeviceAuthentication)
                if security.appLockEnabled {
                    Picker(String(localized: "Require Unlock"), selection: $security.lockGrace) {
                        ForEach(LockGrace.allCases) { Text($0.title).tag($0) }
                    }
                }
                Toggle(String(localized: "Hide Content in App Switcher"), isOn: $security.privacyCoverEnabled)
            }
            Section {
                LabeledContent(String(localized: "Encryption"), value: "AES-256-GCM · WZCE v1")
                LabeledContent(String(localized: "Key storage"), value: model.keyVault.protection)
                LabeledContent(String(localized: "Vault fingerprint"), value: String((model.keyVault.fingerprint ?? "—").prefix(16)))
                if let revealedKey {
                    Text(revealedKey).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                } else {
                    Button(String(localized: "Show Recovery Key")) {
                        Task {
                            guard await model.lock.confirmOwner(reason: String(localized: "Show your recovery key")),
                                  let key = try? model.keyVault.recoveryKey() else { return }
                            revealedKey = RecoveryKit.format(key)
                        }
                    }
                }
            } header: { Text(String(localized: "End-to-End Encryption")) } footer: {
                Text(String(localized: "Files, filenames and metadata are encrypted on this iPhone before upload. The server never receives your keys."))
            }
            Section {
                Toggle(String(localized: "Also remove recovery key from this iPhone"), isOn: $forgetKey)
                Button(String(localized: "Disconnect This iPhone"), role: .destructive) { confirmDisconnect = true }
            } footer: {
                Text(String(localized: "Removes server credentials and the local queue. Backups on the server are not deleted."))
            }
        }
        .navigationTitle(String(localized: "Security"))
        .onDisappear { revealedKey = nil }
        .confirmationDialog(String(localized: "Disconnect this iPhone?"), isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button(String(localized: "Disconnect"), role: .destructive) { Task { await model.disconnect(forgetRecoveryKey: forgetKey) } }
        } message: {
            Text(forgetKey ? String(localized: "Make sure your recovery key is written down; without it the backups cannot be decrypted.") : String(localized: "Your recovery key stays on this iPhone."))
        }
    }
}

struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "lock.shield.fill").font(.system(size: 54)).foregroundStyle(Theme.heroGradient)
                    Text(AppConfig.appName).font(.title2.bold())
                    Text(String(localized: "Version \(AppConfig.appVersion)")).font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
            Section {
                LabeledContent(String(localized: "Developer"), value: AppConfig.developerName)
                Link(destination: AppConfig.developerWebsite) { LabeledContent(String(localized: "Website"), value: "wezcrypt.com") }
                LabeledContent(String(localized: "Encryption"), value: String(localized: "Client-side AES-256-GCM"))
                LabeledContent(String(localized: "Transfer"), value: "HTTPS")
            }
        }
        .navigationTitle(String(localized: "About"))
    }
}
