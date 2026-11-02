import CryptoKit
import Darwin
import Foundation

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
    /// Each copy's attributes after its readback verification, binding `hashes` to that exact file.
    let versions: [String: stat]
    /// Holds the directory's owner lock so launch cleanup never removes a live snapshot.
    private let lock: Int32
    init(directory: URL, hashes: [String: String], origins: [String: String], versions: [String: stat] = [:], lock: Int32 = -1) {
        self.directory = directory; self.hashes = hashes; self.origins = origins; self.versions = versions; self.lock = lock
    }
    /// Complete transfer hashes the preview can use instead of rereading each copy.
    var transferred: [String: (version: stat, hash: String)] {
        Dictionary(uniqueKeysWithValues: hashes.compactMap { path, hash in versions[path].map { (path, ($0, hash)) } })
    }
    // Remove before unlocking, so no other process can see an unlocked live snapshot.
    deinit { try? FileManager.default.removeItem(at: directory); if lock >= 0 { close(lock) } }
}

enum CameraStaging {
    static func component(_ name: String) throws {
        try Importer.validateComponent(name)
        guard !name.contains(":"), !name.contains("\\"), !name.contains("\0") else { throw ImportError("The camera returned an unsafe filename.") }
    }

    /// Runs off the main thread. `read` is injectable so failure/short-read/cancellation
    /// safety can be tested without any physical camera or personal photos.
    static func prepare(
        _ objects: [CameraObject], camera: String, cancellation: Cancellation,
        temporaryRoot: URL? = nil,
        read: (CameraObject, Int64, Int) throws -> Data,
        progress: (ImportProgress) -> Void
    ) throws -> CameraSnapshot {
        // Foundation normalizes /private/var back to the /var symlink even after
        // resolving it. Use disposable user-cache storage so the importer's strict
        // source-symlink refusal remains intact, including on macOS temporary paths.
        let root = try temporaryRoot ?? workingDirectory()
        try Importer.assertDirectory(root)
        let directory = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        // Hidden, so source listings skip it. The kernel releases the lock if the process dies.
        let lock = open(directory.appendingPathComponent(ownerLock).path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        var keep = false
        defer { if !keep { try? FileManager.default.removeItem(at: directory); if lock >= 0 { close(lock) } } }
        guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw ImportError("Cannot create the temporary camera copy. Check free disk space.") }
        var hashes: [String: String] = [:], origins: [String: String] = [:], versions: [String: stat] = [:], paths = Set<String>(), ids = Set<String>()
        let files = objects.filter { MediaTypes.importable.contains(($0.name as NSString).pathExtension.lowercased()) }
        guard !files.isEmpty else { throw ImportError("No supported originals were found on this camera.") }
        // Validate the whole catalog before reading anything. Refuse ambiguous names on
        // case-insensitive filesystems instead of overwriting or merging unrelated groups.
        for file in files {
            try component(file.name); try file.folders.forEach(component)
            guard file.size >= 0, ids.insert(file.id).inserted,
                paths.insert((file.folders + [file.name]).joined(separator: "/").lowercased()).inserted
            else {
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
                let version = try Importer.info(target)
                let (actual, size) = try Importer.digest(target, cancellation: cancellation)
                guard size == UInt64(file.size), actual == expected, Importer.stable(version, try Importer.info(target)) else {
                    throw ImportError("The temporary camera copy did not verify. No destination files were copied.")
                }
                hashes[target.path] = expected; versions[target.path] = version
                origins[target.path] = camera + "/" + (file.originalPath ?? (file.folders + [file.name]).joined(separator: "/"))
            }
        }
        try cancellation.check()
        keep = true
        return CameraSnapshot(directory: directory, hashes: hashes, origins: origins, versions: versions, lock: lock)
    }

    static let ownerLock = ".owner.lock"
    static let prefix = "corvus-camera-"

    /// Temporary copies left by a process that quit or crashed mid-preview. A snapshot whose
    /// owner lock can be taken has no live owner. Folders from before owner locks are removed
    /// once older than `grace`, which also covers the instant between mkdir and locking.
    /// Returns the number of folders removed. Never follows links; only this app's folders match.
    /// Pass the earlier name's folder and prefix to clean snapshots left before the Corvus rename.
    @discardableResult
    static func removeAbandoned(in root: URL? = nil, prefix: String = prefix, grace: TimeInterval = 60 * 60, now: Date = Date()) -> Int {
        guard let root = try? root ?? workingDirectory(), (try? Importer.assertDirectory(root)) != nil,
            let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix(prefix) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            guard let value = try? Importer.info(directory), value.st_mode & S_IFMT == S_IFDIR else { continue }
            let lock = open(directory.appendingPathComponent(ownerLock).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if lock >= 0 {
                defer { close(lock) }
                // Hold the lock while removing so a live owner can't appear mid-removal.
                guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { continue }
                if (try? FileManager.default.removeItem(at: directory)) != nil { removed += 1 }
            } else if errno == ENOENT, now.timeIntervalSince1970 - TimeInterval(value.st_birthtimespec.tv_sec) > grace {
                if (try? FileManager.default.removeItem(at: directory)) != nil { removed += 1 }
            }
        }
        return removed
    }

    static func workingDirectory() throws -> URL {
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = caches.appendingPathComponent("Corvus/CameraTransfers", isDirectory: true)
        // Validate existing ancestors before creating our own directories.
        try Importer.assertDirectory(caches)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Importer.assertDirectory(directory)
        return directory
    }
}
