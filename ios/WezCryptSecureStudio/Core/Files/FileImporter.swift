import Foundation
import UniformTypeIdentifiers

/// Copies documents picked with the system document picker (Files app) into the
/// app's private staging area, then queues them for encrypted backup. The copy
/// is needed because security-scoped access ends when the picker returns and
/// background uploads may run much later. Staged copies are deleted once the
/// encrypted backup is verified on the server.
struct FileImporter: Sendable {
    let stagingDirectory: URL
    let storage: StorageGuard

    struct Imported: Sendable {
        let localID: String
        let displayName: String
        let stagedName: String
        let size: Int64
        let createdAt: Date?
    }

    func importFiles(_ urls: [URL]) throws -> (imported: [Imported], failures: [String]) {
        var imported: [Imported] = []
        var failures: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey, .creationDateKey, .nameKey])
                if values.isDirectory == true {
                    failures.append(String(localized: "\(url.lastPathComponent): folders are not supported; select the files inside."))
                    continue
                }
                let size = Int64(values.fileSize ?? 0)
                try storage.ensure(size)
                let stagedName = UUID().uuidString
                let destination = stagingDirectory.appendingPathComponent(stagedName)
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [.forUploading], error: &coordinationError) { readableURL in
                    do {
                        try FileManager.default.copyItem(at: readableURL, to: destination)
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
                    } catch {
                        copyError = error
                    }
                }
                if let error = coordinationError ?? copyError { throw error }
                let actualSize = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? size
                imported.append(Imported(localID: "file:\(stagedName)", displayName: values.name ?? url.lastPathComponent,
                                         stagedName: stagedName, size: actualSize, createdAt: values.creationDate))
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        return (imported, failures)
    }
}
