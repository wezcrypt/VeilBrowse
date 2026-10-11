import Foundation
import LocalAuthentication
import Observation

/// Face ID / passcode app lock plus a privacy cover that hides content in the
/// app switcher snapshot.
@MainActor
@Observable
final class AppLockController {
    private(set) var isLocked = false
    private(set) var isObscured = false
    private(set) var isAuthenticating = false
    private(set) var lastError: String?
    private var backgroundedAt: Date?
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    var biometryType: LABiometryType {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return context.biometryType
    }

    var canUseDeviceAuthentication: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    var biometryName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return String(localized: "Passcode")
        }
    }

    var biometrySymbol: String {
        switch biometryType {
        case .faceID: return "faceid"
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "lock.fill"
        }
    }

    private var lockApplies: Bool {
        settings.appLockEnabled && canUseDeviceAuthentication
    }

    func lockOnLaunch(signedIn: Bool) {
        isLocked = signedIn && lockApplies
    }

    func sceneBecameInactive() {
        if settings.privacyCoverEnabled { isObscured = true }
    }

    func sceneEnteredBackground() {
        if settings.privacyCoverEnabled { isObscured = true }
        backgroundedAt = Date()
    }

    func sceneBecameActive(signedIn: Bool) {
        isObscured = false
        if let backgroundedAt, signedIn, lockApplies,
           Date().timeIntervalSince(backgroundedAt) >= TimeInterval(settings.lockGrace.rawValue) {
            isLocked = true
        }
        backgroundedAt = nil
    }

    func lockNow() {
        if lockApplies { isLocked = true }
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }
        let context = LAContext()
        context.localizedFallbackTitle = String(localized: "Use Passcode")
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: String(localized: "Unlock your private vault")
            )
            if success {
                isLocked = false
                lastError = nil
            }
        } catch let error as LAError where error.code == .userCancel || error.code == .appCancel || error.code == .systemCancel {
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Verifies the owner before enabling or disabling the lock.
    func confirmOwner(reason: String) async -> Bool {
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
