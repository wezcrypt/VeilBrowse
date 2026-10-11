import Foundation
import Observation
import UIKit

/// Device pairing and session lifecycle. The app never sees Telegram initData,
/// the bot token or any server encryption key: the owner approves this device by
/// sending a short-lived code to the existing Telegram bot.
@MainActor
@Observable
final class AuthManager {
    struct PairingTicket: Equatable, Sendable {
        let code: String
        let expiresAt: Date
        let telegramLink: URL?
        let botUsername: String?
    }

    enum State: Equatable {
        case unknown
        case signedOut
        case pairing(PairingTicket)
        case signedIn(deviceID: String)
    }

    private(set) var state: State = .unknown
    private(set) var isWorking = false
    var lastError: String?

    private let api: APIClient
    private let credentials: SessionCredentialStore
    private let deviceKeys: DeviceKeyManager
    private var pollTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    var onSignedOut: (() async -> Void)?

    init(api: APIClient, credentials: SessionCredentialStore, deviceKeys: DeviceKeyManager) {
        self.api = api
        self.credentials = credentials
        self.deviceKeys = deviceKeys
    }

    var isSignedIn: Bool {
        if case .signedIn = state { return true }
        return false
    }

    func bootstrap() async {
        if let current = await credentials.current(), current.refreshExpiresAt > Date() {
            state = .signedIn(deviceID: current.deviceId)
        } else {
            await credentials.clear()
            state = .signedOut
        }
        watchTask?.cancel()
        watchTask = Task { [weak self, credentials] in
            for await signedIn in credentials.changes {
                guard let self else { return }
                if !signedIn {
                    await self.handleSessionEnded()
                }
            }
        }
    }

    // MARK: Pairing

    func startPairing() async {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        defer { isWorking = false }
        do {
            let publicKey = try deviceKeys.rotate()
            let device = UIDevice.current
            let request = PairStartRequest(
                deviceName: String(device.name.prefix(80)),
                deviceModel: Self.modelIdentifier(),
                systemVersion: "\(device.systemName) \(device.systemVersion)",
                publicKey: publicKey.base64EncodedString()
            )
            let response = try await api.startPairing(request)
            let ticket = PairingTicket(
                code: response.code,
                expiresAt: response.expiresAt,
                telegramLink: response.telegramLink.flatMap(URL.init(string:)),
                botUsername: response.botUsername
            )
            state = .pairing(ticket)
            startPolling(pairingID: response.pairingId, secret: response.pollSecret, interval: response.pollInterval, expiresAt: response.expiresAt)
        } catch {
            lastError = error.localizedDescription
            state = .signedOut
        }
    }

    func cancelPairing() {
        pollTask?.cancel()
        pollTask = nil
        state = .signedOut
    }

    private func startPolling(pairingID: String, secret: String, interval: Int, expiresAt: Date) {
        pollTask?.cancel()
        let body = PairPollRequest(pairingId: pairingID, pollSecret: secret)
        let sleepSeconds = UInt64(max(interval, 2))
        pollTask = Task { [weak self, api] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: sleepSeconds * 1_000_000_000)
                guard !Task.isCancelled else { return }
                do {
                    let response = try await api.pollPairing(body)
                    switch response.status {
                    case "approved":
                        if let session = response.session {
                            await self?.completePairing(session)
                        }
                        return
                    case "expired", "consumed":
                        self?.pairingExpired()
                        return
                    default:
                        if Date() > expiresAt.addingTimeInterval(5) {
                            self?.pairingExpired()
                            return
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // Transient network errors: keep polling until the code expires.
                    if Date() > expiresAt.addingTimeInterval(5) {
                        self?.pairingExpired()
                        return
                    }
                }
            }
        }
    }

    private func completePairing(_ session: SessionCredentials) async {
        do {
            try await credentials.save(session)
            state = .signedIn(deviceID: session.deviceId)
            Log.auth.info("Device paired")
        } catch {
            lastError = error.localizedDescription
            state = .signedOut
        }
    }

    private func pairingExpired() {
        lastError = String(localized: "The pairing code expired. Generate a new one.")
        state = .signedOut
    }

    // MARK: Session

    func signOut() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await api.logout()
        } catch {
            Log.auth.notice("Logout request failed; clearing local session anyway")
        }
        await credentials.clear()
        await handleSessionEnded()
    }

    private func handleSessionEnded() async {
        guard state != .signedOut else { return }
        pollTask?.cancel()
        deviceKeys.reset()
        state = .signedOut
        await onSignedOut?()
    }

    func devices() async throws -> [DeviceInfo] {
        try await api.devices()
    }

    func revoke(_ device: DeviceInfo) async throws {
        try await api.revokeDevice(device.id)
        if device.isCurrent {
            await credentials.clear()
        }
    }

    static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let identifier = mirror.children.reduce(into: "") { result, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            result.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "iPhone" : String(identifier.prefix(80))
    }
}
