import CryptoKit
import Foundation

/// Real end-to-end connection test: reachability over trusted HTTPS,
/// authentication, account/storage, then upload, read back, verify and delete
/// an encrypted test object in two chunks. Success is reported only when every
/// step passed.
struct ConnectionTester: Sendable {
    enum Step: String, CaseIterable, Sendable, Identifiable {
        case reachability, authentication, storage, write, readBack, cleanup

        var id: String { rawValue }

        var title: String {
            switch self {
            case .reachability: return String(localized: "Secure connection (HTTPS)")
            case .authentication: return String(localized: "Authentication")
            case .storage: return String(localized: "Account & free space")
            case .write: return String(localized: "Upload encrypted test file")
            case .readBack: return String(localized: "Download & verify")
            case .cleanup: return String(localized: "Delete test file")
            }
        }
    }

    enum StepState: Sendable, Equatable {
        case pending
        case running
        case passed(String)
        case failed(String)
    }

    struct Report: Sendable {
        var account: AccountInfo?
        var vaultFingerprint: String?
        var succeeded: Bool
    }

    let api: BackupAPI
    var payloadSize = 300 * 1024

    func run(update: @escaping @Sendable (Step, StepState) async -> Void) async -> Report {
        var report = Report(succeeded: false)
        var current: Step = .reachability
        do {
            await update(.reachability, .running)
            let started = Date()
            try await api.health()
            await update(.reachability, .passed(String(format: "%.0f ms", Date().timeIntervalSince(started) * 1000)))

            current = .authentication
            await update(.authentication, .running)
            let account = try await api.account()
            report.account = account
            await update(.authentication, .passed(String(localized: "Signed in as \(account.username)")))

            current = .storage
            await update(.storage, .running)
            report.vaultFingerprint = try await api.vault()?.fingerprint
            let quota = account.quotaBytes.map { String(localized: " · quota \(Formatters.bytes($0))") } ?? ""
            await update(.storage, .passed(String(localized: "\(Formatters.bytes(account.diskFreeBytes)) free\(quota)")))

            current = .write
            await update(.write, .running)
            let key = SymmetricKey(size: .bits256)
            let objectID = WZCE.randomBytes(16)
            let plaintext = WZCE.randomBytes(payloadSize)
            let directory = try AppDirectories.secureTemp("ConnectionTest")
            defer { AppDirectories.wipe(directory) }
            let chunkSize = 160 * 1024
            let prepared = try ChunkPreparer.encrypt(data: plaintext, objectID: objectID, kek: key, chunkSize: chunkSize, into: directory)
            let session = try await api.createUpload(objectID: prepared.objectID, sizeBytes: prepared.cipherSize, chunkSize: chunkSize,
                                                     chunkCount: prepared.chunks.count, sha256: prepared.cipherSHA256)
            guard let uploadID = session.uploadId else { throw APIError.invalidResponse }
            let transport = ForegroundChunkTransport()
            for chunk in prepared.chunks {
                let request = try api.chunkRequest(uploadID: uploadID, index: chunk.index, sha256: chunk.sha256, token: try await api.bearerToken())
                let (response, body) = try await transport.upload(request, fromFile: chunk.url)
                guard (200..<300).contains(response.statusCode) else { throw APIError.from(status: response.statusCode, data: body) }
            }
            let completed = try await api.completeUpload(uploadID)
            guard completed.sha256 == prepared.cipherSHA256 else { throw APIError.invalidResponse }
            await update(.write, .passed(String(localized: "\(prepared.chunks.count) chunks verified by the server")))

            current = .readBack
            await update(.readBack, .running)
            let downloaded = try await api.downloadObject(prepared.objectID, to: directory)
            let roundTrip = try WZCE.decrypt(Data(contentsOf: downloaded), kek: key, expectedObjectID: objectID)
            guard roundTrip == plaintext else { throw RestoreError.integrity("test file") }
            await update(.readBack, .passed(String(localized: "Decrypted copy is identical")))

            current = .cleanup
            await update(.cleanup, .running)
            try await api.deleteObject(prepared.objectID)
            await update(.cleanup, .passed(String(localized: "Removed")))
            report.succeeded = true
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            await update(current, .failed(message))
        }
        return report
    }
}
