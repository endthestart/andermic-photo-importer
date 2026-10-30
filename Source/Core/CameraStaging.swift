import Foundation
import CryptoKit
import Darwin

/// A read-only camera object. Folder identifiers (not names) keep card slots and reused
/// filenames separate. The transport must return the original bytes, never a rendition.
struct CameraObject {
    let id: String
    let folders: [String]
    let name: String
    let size: Int64
    var originalPath: String? = nil
}

/// Owns only this operation's private temporary directory. Nothing on a camera is removed.
final class CameraSnapshot {
    let directory: URL
    let hashes: [String: String]
    let origins: [String: String]
    init(directory: URL, hashes: [String: String], origins: [String: String]) {
        self.directory = directory; self.hashes = hashes; self.origins = origins
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
}

enum CameraStaging {
    static func component(_ name: String) throws {
        try Importer.validateComponent(name)
        guard !name.contains(":"), !name.contains("\\"), !name.contains("\0") else { throw ImportError("The camera returned an unsafe filename.") }
    }

    /// Runs off the main thread. `read` is injectable so failure/short-read/cancellation
    /// safety can be tested without any physical camera or personal photos.
    static func prepare(_ objects: [CameraObject], camera: String, cancellation: Cancellation,
                        temporaryRoot: URL? = nil,
                        read: (CameraObject, Int64, Int) throws -> Data,
                        progress: (ImportProgress) -> Void) throws -> CameraSnapshot {
        // Foundation normalizes /private/var back to the /var symlink even after
        // resolving it. Use disposable user-cache storage so the importer's strict
        // source-symlink refusal remains intact, including on macOS temporary paths.
        let root = try temporaryRoot ?? workingDirectory()
        try Importer.assertDirectory(root)
        let directory = root.appendingPathComponent("andermic-camera-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: directory) } }
        var hashes: [String: String] = [:], origins: [String: String] = [:], paths = Set<String>(), ids = Set<String>()
        let files = objects.filter { MediaTypes.importable.contains(($0.name as NSString).pathExtension.lowercased()) }
        guard !files.isEmpty else { throw ImportError("No supported originals were found on this camera.") }
        // Validate the whole catalog before reading anything. Refuse ambiguous names on
        // case-insensitive filesystems instead of overwriting or merging unrelated groups.
        for file in files {
            try component(file.name); try file.folders.forEach(component)
            guard file.size >= 0, ids.insert(file.id).inserted,
                  paths.insert((file.folders + [file.name]).joined(separator: "/").lowercased()).inserted else {
                throw ImportError("The camera returned an ambiguous or invalid file catalog.")
            }
        }
        var lastProgress = Date.distantPast
        for (index, file) in files.enumerated() {
          try autoreleasepool {
            try cancellation.check()
            let target = (file.folders + [file.name]).reduce(directory) { $0.appendingPathComponent($1) }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let fd = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw ImportError("Cannot create the temporary camera copy. Check free disk space.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var offset: Int64 = 0, hash = SHA256()
            do {
                while offset < file.size {
                  try autoreleasepool {
                    try cancellation.check()
                    let count = Int(min(4 * 1024 * 1024, file.size - offset))
                    let now = Date()
                    if now.timeIntervalSince(lastProgress) >= 0.1 {
                        lastProgress = now
                        progress(ImportProgress("Reading camera original \(index + 1) of \(files.count): \(file.name). Temporary copies are needed before preview.", fraction: nil))
                    }
                    let data = try read(file, offset, count)
                    try cancellation.check()
                    guard !data.isEmpty, data.count <= count else { throw ImportError("The camera returned incomplete or invalid original data. Scan again.") }
                    try handle.write(contentsOf: data); hash.update(data: data); offset += Int64(data.count)
                  }
                }
                try handle.synchronize(); try handle.close()
            } catch { try? handle.close(); throw error }
            let expected = hash.finalize().map { String(format: "%02x", $0) }.joined()
            let (actual, size) = try Importer.digest(target, cancellation: cancellation)
            guard size == UInt64(file.size), actual == expected else { throw ImportError("The temporary camera copy did not verify. No destination files were copied.") }
            hashes[target.path] = expected
            origins[target.path] = camera + "/" + (file.originalPath ?? (file.folders + [file.name]).joined(separator: "/"))
          }
        }
        try cancellation.check()
        keep = true
        return CameraSnapshot(directory: directory, hashes: hashes, origins: origins)
    }

    static func workingDirectory() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches.appendingPathComponent("Andermic Photo Importer/CameraTransfers", isDirectory: true)
        // Validate existing ancestors before creating our own directories.
        try Importer.assertDirectory(caches)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Importer.assertDirectory(directory)
        return directory
    }
}
