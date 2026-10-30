import Foundation
import CryptoKit
import Darwin

/// Rebuildable hints for previews only. Import never uses this cache to skip a read.
/// Expiry is measured from a complete hash, not from the last cache hit.
final class DuplicateVerificationCache {
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60
    static let maximumEntries = 10_000
    static let maximumBytes = 8 * 1024 * 1024

    private struct Identity: Codable, Equatable {
        let device: Int64, inode: UInt64, size: Int64
        let modified: Int64, modifiedNS: Int64, changed: Int64, changedNS: Int64
        let born: Int64, bornNS: Int64
        init(_ value: stat) {
            device = Int64(value.st_dev); inode = UInt64(value.st_ino); size = value.st_size
            modified = Int64(value.st_mtimespec.tv_sec); modifiedNS = Int64(value.st_mtimespec.tv_nsec)
            changed = Int64(value.st_ctimespec.tv_sec); changedNS = Int64(value.st_ctimespec.tv_nsec)
            born = Int64(value.st_birthtimespec.tv_sec); bornNS = Int64(value.st_birthtimespec.tv_nsec)
        }
    }
    private struct Entry: Codable {
        let key: String, identity: Identity, sample: String, hash: String
        let verifiedAt: TimeInterval
    }
    private struct Document: Codable { let version: Int; let entries: [Entry] }
    private let directory: URL
    let file: URL
    private let clock: () -> Date
    private let entryLimit: Int, byteLimit: Int
    private var entries: [String: Entry] = [:]
    var count: Int { entries.count }

    init(directory: URL, clock: @escaping () -> Date = Date.init,
         entryLimit: Int = maximumEntries, byteLimit: Int = maximumBytes) {
        self.directory = directory.standardizedFileURL
        file = directory.appendingPathComponent("verified-hashes-v1.json")
        self.clock = clock
        self.entryLimit = max(0, min(entryLimit, Self.maximumEntries))
        self.byteLimit = max(64, min(byteLimit, Self.maximumBytes))
        load(); prune()
    }

    /// Copies an earlier install's cache file once, so the first scan after a rename is not cold. The earlier file stays.
    static func adopt(from previous: URL, into directory: URL) {
        let name = "verified-hashes-v1.json", source = previous.appendingPathComponent(name), target = directory.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path), FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? FileManager.default.copyItem(at: source, to: target)
    }

    /// Root identity prevents reuse across a replaced destination or another volume.
    static func namespace(root: URL) -> String? {
        guard let info = try? Importer.info(root), info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return digest("\(root.standardizedFileURL.path)\u{0}\(info.st_dev):\(info.st_ino)")
    }
    private static func digest(_ text: String) -> String {
        let digits = Array("0123456789abcdef".utf8)
        return String(decoding: SHA256.hash(data: Data(text.utf8)).flatMap { [digits[Int($0 >> 4)], digits[Int($0 & 15)]] }, as: UTF8.self)
    }
    private func key(_ url: URL, _ namespace: String) -> String {
        Self.digest(namespace + "\u{0}" + url.standardizedFileURL.path)
    }
    private static func validHash(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private func fresh(_ entry: Entry) -> Bool {
        let age = clock().timeIntervalSince1970 - entry.verifiedAt
        return entry.verifiedAt.isFinite && age >= 0 && age < Self.lifetime
    }
    func hash(for url: URL, namespace: String, info: stat, sample: String) -> String? {
        let id = key(url, namespace)
        guard let entry = entries[id] else { return nil }
        guard fresh(entry), info.st_mode & S_IFMT == S_IFREG,
              entry.identity == Identity(info), entry.sample == sample else {
            entries.removeValue(forKey: id); return nil
        }
        // Deliberately do not update verifiedAt on a hit.
        return entry.hash
    }
    /// Call only after hashing complete contents and checking identity stability.
    func record(_ url: URL, namespace: String, info: stat, sample: String, hash: String) {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              Self.validHash(sample), Self.validHash(hash) else { return }
        let id = key(url, namespace)
        entries[id] = Entry(key: id, identity: Identity(info), sample: sample, hash: hash,
                            verifiedAt: clock().timeIntervalSince1970)
        if entries.count > entryLimit { prune() }
    }
    private func newest() -> [Entry] {
        entries.values.sorted { $0.verifiedAt == $1.verifiedAt ? $0.key < $1.key : $0.verifiedAt > $1.verifiedAt }
    }
    private func prune() {
        entries = entries.filter { fresh($0.value) }
        if entries.count > entryLimit {
            // Evict a small batch to avoid sorting 10,000 entries for every new file.
            let retained = max(0, entryLimit - max(1, entryLimit / 10))
            entries = Dictionary(uniqueKeysWithValues: newest().prefix(retained).map { ($0.key, $0) })
        }
    }
    private func load() {
        // No unbounded Data(contentsOf:), symlink following, or permissive cache files.
        guard (try? Importer.assertDirectory(directory)) != nil else { return }
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }; defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_mode & 0o077 == 0,
              before.st_size >= 0, before.st_size <= byteLimit else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: byteLimit + 1), data.count <= byteLimit,
              let document = try? JSONDecoder().decode(Document.self, from: data), document.version == 1,
              document.entries.count <= entryLimit else { return }
        var after = stat()
        guard fstat(fd, &after) == 0, Importer.stable(before, after) else { return }
        for entry in document.entries where fresh(entry) && Self.validHash(entry.key)
            && Self.validHash(entry.sample) && Self.validHash(entry.hash) && entry.identity.size >= 0 {
            entries[entry.key] = entry
        }
    }
    /// Best effort. Cache failure always falls back to normal verification.
    /// Concurrent processes may lose hints through last-writer-wins; never safety evidence.
    func save() {
        prune()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Importer.assertDirectory(directory)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var ordered = newest()
            var data = try encoder.encode(Document(version: 1, entries: ordered))
            while data.count > byteLimit && !ordered.isEmpty {
                ordered.removeLast(max(1, ordered.count / 8))
                data = try encoder.encode(Document(version: 1, entries: ordered))
            }
            guard data.count <= byteLimit else { return }
            entries = Dictionary(uniqueKeysWithValues: ordered.map { ($0.key, $0) })
            let temporary = directory.appendingPathComponent(".cache-\(UUID().uuidString).tmp")
            let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { return }
            defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: data)
            try Importer.assertDirectory(directory)
            guard rename(temporary.path, file.path) == 0 else { return }
        } catch { /* Losing a cache entry costs reads, never originals. */ }
    }
}
