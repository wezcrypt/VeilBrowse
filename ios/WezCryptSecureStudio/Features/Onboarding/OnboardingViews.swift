import CryptoKit
import Photos
import SwiftUI

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                switch model.stage {
                case .welcome: WelcomeView()
                case .serverSetup: ServerSetupView()
                case .connectionTest: ConnectionTestView()
                case .recovery: RecoverySetupView()
                case .permissions: PhotoPermissionView()
                case .ready: EmptyView()
                }
            }
            .transition(.opacity)
        }
    }
}

struct WelcomeView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ZStack {
                    RoundedRectangle(cornerRadius: 28, style: .continuous).fill(Theme.heroGradient).frame(width: 104, height: 104)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 24, y: 12)
                    Image(systemName: "lock.shield.fill").font(.system(size: 50, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(.top, 48)
                .accessibilityHidden(true)
                VStack(spacing: 10) {
                    Text(AppConfig.appName).font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text(String(localized: "End-to-end encrypted backup of your photos, videos and files to your own server."))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 18) {
                    feature("lock.fill", String(localized: "Encrypted on this iPhone"), String(localized: "AES-256-GCM with a unique key per file. Your server only stores ciphertext."))
                    feature("photo.stack", String(localized: "Originals, untouched"), String(localized: "HEIC, RAW, ProRAW, Live Photos and videos are copied bit-for-bit."))
                    feature("arrow.clockwise.icloud", String(localized: "Resumable"), String(localized: "Large files upload in verified chunks and continue after interruptions."))
                    feature("key.fill", String(localized: "You hold the key"), String(localized: "A recovery key restores everything on a new device. Nobody else can decrypt it."))
                }
                .padding(.horizontal, 8)
                Button(String(localized: "Get Started")) { model.go(to: .serverSetup) }
                    .buttonStyle(PrimaryButtonStyle())
                    .accessibilityIdentifier("getStarted")
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background.ignoresSafeArea())
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct ServerSetupView: View {
    @Environment(AppModel.self) private var model
    @State private var serverURL = AppConfig.defaultServerURL
    @State private var transport: TransferProtocol = .https
    @State private var authMethod: AuthMethod = .password
    @State private var username = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var collection = AppConfig.defaultCollection
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField(String(localized: "Server URL"), text: $serverURL)
                    .textContentType(.URL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("serverURL")
                Picker(String(localized: "Connection Protocol"), selection: $transport) {
                    ForEach(TransferProtocol.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text(String(localized: "Server"))
            } footer: {
                Text(String(localized: "Only HTTPS with a certificate trusted by iOS is accepted."))
            }

            Section(String(localized: "HTTPS Authentication")) {
                Picker(String(localized: "Method"), selection: $authMethod) {
                    ForEach(AuthMethod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if authMethod == .password {
                    TextField(String(localized: "Username"), text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("username")
                    SecureField(String(localized: "Password"), text: $password)
                        .textContentType(.password)
                        .accessibilityIdentifier("password")
                } else {
                    SecureField(String(localized: "API Key (wzk_…)"), text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                }
            }

            Section {
                TextField(String(localized: "Backup Directory"), text: $collection)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            } footer: {
                Text(String(localized: "Folder on the server inside iphone-backups/<username>/. Use a different name per device if you back up several devices."))
            }

            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
            }

            Section {
                Button {
                    Task { await save() }
                } label: {
                    HStack {
                        Spacer()
                        if saving { ProgressView() } else { Text(String(localized: "Save Configuration & Test Connection")).bold() }
                        Spacer()
                    }
                }
                .disabled(saving)
                .accessibilityIdentifier("saveConfiguration")
            } footer: {
                Text(String(localized: "Passwords and API keys are stored only in the iOS Keychain on this device."))
            }
        }
        .navigationTitle(String(localized: "Server Setup"))
        .onAppear(perform: loadExisting)
    }

    private func loadExisting() {
        guard let config = model.configuration else { return }
        serverURL = config.serverURL.absoluteString
        transport = config.transport
        authMethod = config.authMethod
        username = config.username
        collection = config.collection
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let url = try ServerConfiguration.normalizedURL(serverURL)
            let config = ServerConfiguration(serverURL: url, transport: transport, authMethod: authMethod,
                                             username: username.trimmingCharacters(in: .whitespaces).lowercased(),
                                             collection: collection.trimmingCharacters(in: .whitespaces))
            try await model.saveConfiguration(config, secret: authMethod == .password ? password : apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
            error = nil
            model.go(to: .connectionTest)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct ConnectionTestView: View {
    @Environment(AppModel.self) private var model
    @State private var states: [ConnectionTester.Step: ConnectionTester.StepState] = [:]
    @State private var running = false
    @State private var report: ConnectionTester.Report?

    var body: some View {
        List {
            Section {
                ForEach(ConnectionTester.Step.allCases) { step in
                    StepRow(title: step.title, state: states[step] ?? .pending)
                }
            } footer: {
                Text(String(localized: "The test uploads a small encrypted file in two chunks, downloads and decrypts it, compares it byte-for-byte, then deletes it."))
            }
            if let report {
                Section {
                    if report.succeeded {
                        Label(String(localized: "Connection successful"), systemImage: "checkmark.seal.fill").foregroundStyle(Theme.success).font(.headline)
                            .accessibilityIdentifier("connectionSuccessful")
                        Button(String(localized: "Continue")) { Task { await model.continueAfterConnectionTest(report: report) } }.bold()
                    } else {
                        Label(String(localized: "Connection test failed"), systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger).font(.headline)
                        Button(String(localized: "Edit Server Settings")) { model.go(to: .serverSetup) }
                        Button(String(localized: "Run Test Again")) { Task { await run() } }
                    }
                }
            }
        }
        .navigationTitle(String(localized: "Connection Test"))
        .task { if report == nil { await run() } }
    }

    private func run() async {
        guard !running else { return }
        running = true
        report = nil
        states = [:]
        report = await model.testConnection { step, state in
            await MainActor.run { states[step] = state }
        }
        running = false
    }
}

struct StepRow: View {
    let title: String
    let state: ConnectionTester.StepState

    var body: some View {
        HStack(spacing: 12) {
            Group {
                switch state {
                case .pending: Image(systemName: "circle").foregroundStyle(.tertiary)
                case .running: ProgressView()
                case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.danger)
                }
            }
            .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                switch state {
                case .passed(let detail): Text(detail).font(.caption).foregroundStyle(.secondary)
                case .failed(let message): Text(message).font(.caption).foregroundStyle(Theme.danger)
                default: EmptyView()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct RecoverySetupView: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode?
    @State private var generated: SymmetricKey?
    @State private var confirmation = ""
    @State private var imported = ""
    @State private var savedConfirmed = false
    @State private var error: String?
    @State private var working = false
    @State private var serverHasVault: Bool?

    enum Mode { case create, restore }

    var body: some View {
        Form {
            Section {
                Text(String(localized: "Your recovery key is the master key for all backups. It never leaves your devices. Without it, nobody — not even the server owner — can decrypt your data, and lost keys cannot be reset."))
                    .font(.subheadline)
            }
            if serverHasVault == true {
                Section {
                    Label(String(localized: "This account already has encrypted backups. Enter the recovery key you saved when they were created."), systemImage: "key.horizontal")
                }
            }
            Section {
                if serverHasVault != true {
                    Button(String(localized: "Create a New Recovery Key")) { createKey() }
                        .accessibilityIdentifier("createRecoveryKey")
                }
                Button(String(localized: "I Already Have a Recovery Key")) { mode = .restore }
            }
            if mode == .create, let generated {
                let text = RecoveryKit.format(generated)
                Section {
                    Text(text)
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                        .accessibilityLabel(text.map { String($0) }.joined(separator: " "))
                    Button {
                        UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: text]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(120)])
                    } label: { Label(String(localized: "Copy (clears in 2 minutes)"), systemImage: "doc.on.doc") }
                } header: {
                    Text(String(localized: "Write this down and store it safely"))
                } footer: {
                    Text(String(localized: "Store it offline (paper, password manager). Anyone with this key and your server login can read your backups."))
                }
                Section {
                    Toggle(String(localized: "I have saved my recovery key"), isOn: $savedConfirmed)
                    TextField(String(localized: "Type the last group to confirm"), text: $confirmation)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button(String(localized: "Use This Key")) { Task { await adopt(generated, check: text) } }
                        .disabled(!savedConfirmed || working)
                }
            }
            if mode == .restore {
                Section(String(localized: "Enter Recovery Key")) {
                    TextField("XXXXX-XXXXX-…", text: $imported, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    Button(String(localized: "Restore Key")) { Task { await restore() } }.disabled(working || imported.isEmpty)
                }
            }
            if let error {
                Section { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger) }
            }
        }
        .navigationTitle(String(localized: "Encryption"))
        .task {
            serverHasVault = try? await model.serverHasVault()
            if serverHasVault == true { mode = .restore }
        }
    }

    private func createKey() {
        generated = RecoveryKit.generateKey()
        mode = .create
        confirmation = ""
        savedConfirmed = false
    }

    private func adopt(_ key: SymmetricKey, check text: String) async {
        let lastGroup = text.split(separator: "-").last.map(String.init) ?? ""
        guard confirmation.trimmingCharacters(in: .whitespaces).uppercased() == lastGroup else {
            error = String(localized: "The confirmation does not match the last group of your key.")
            return
        }
        await apply(key)
    }

    private func restore() async {
        do {
            await apply(try RecoveryKit.parse(imported))
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func apply(_ key: SymmetricKey) async {
        working = true
        defer { working = false }
        do {
            try await model.adoptRecoveryKey(SymmetricKeyBox(key: key))
            error = nil
            model.go(to: .permissions)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct PhotoPermissionView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let photos = model.photos
        VStack(spacing: 22) {
            Spacer()
            Image(systemName: "photo.on.rectangle.angled").font(.system(size: 64, weight: .light)).foregroundStyle(Theme.accent)
            Text(String(localized: "Photo Library Access")).font(.title.bold())
            Text(String(localized: "WezCrypt reads your photos and videos to encrypt and back them up. Choose Allow Full Access to back up everything automatically. Nothing is ever deleted from your iPhone."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            switch photos.authorization {
            case .notDetermined:
                Button(String(localized: "Allow Access")) { Task { await photos.requestAccess() } }.buttonStyle(PrimaryButtonStyle())
            case .limited:
                Label(String(localized: "Limited access: only selected items will be backed up."), systemImage: "exclamationmark.circle").font(.footnote)
                Button(String(localized: "Allow Full Access in Settings")) { photos.openSettings() }.buttonStyle(SecondaryButtonStyle())
            case .denied, .restricted:
                Label(String(localized: "Access is off. You can still back up files from the Files app."), systemImage: "lock.slash").font(.footnote)
                Button(String(localized: "Open Settings")) { photos.openSettings() }.buttonStyle(SecondaryButtonStyle())
            default:
                Label(String(localized: "Full access granted"), systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
            }
            Spacer()
            Button(photos.authorization == .notDetermined ? String(localized: "Skip for Now") : String(localized: "Start Backup")) {
                model.finishOnboarding()
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("startBackup")
        }
        .padding(28)
        .navigationTitle(String(localized: "Permissions"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
