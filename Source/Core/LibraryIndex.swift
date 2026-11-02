import Darwin
import Foundation

final class LibraryIndex {
    private var bySize: [UInt64: [URL]] = [:]
    private var byFingerprint: [UInt64: [String: [URL]]] = [:]
    private var cache: [URL: (stat, String)] = [:]
    private var samples: [URL: (stat, String)] = [:]
    private let verificationCache: DuplicateVerificationCache?
    private let cacheNamespace: String?
    private let reuseCachedHashes: Bool
    private(set) var cachedFiles = Set<URL>()
    init(root: URL, cancellation: Cancellation, verificationCache: DuplicateVerificationCache? = nil, reuseCachedHashes: Bool = true) throws {
        self.verificationCache = verificationCache
        self.cacheNamespace = DuplicateVerificationCache.namespace(root: root)
        self.reuseCachedHashes = reuseCachedHashes
        // No persistent catalog: inspect all regular files, including files renamed to unknown extensions.
        for (url, value) in try Self.regularFiles(in: root, cancellation: cancellation) {
            bySize[UInt64(value.st_size), default: []].append(url)
        }
    }
    /// One physical `fts` pass returns each file's attributes with its name, avoiding the URL
    /// enumeration, sort, and second lstat of `Importer.files` (about 6x faster on 100k files).
    /// Like that listing it skips hidden items, package contents, and symlinks, and fails on
    /// unreadable folders rather than silently omitting candidates.
    static func regularFiles(in root: URL, cancellation: Cancellation) throws -> [(URL, stat)] {
        guard let path = strdup(root.standardizedFileURL.path) else { throw ImportError("Cannot list \(root.path)") }
        defer { free(path) }
        var arguments: [UnsafeMutablePointer<CChar>?] = [path, nil]
        guard let walker = fts_open(&arguments, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { throw ImportError("Cannot list \(root.path)") }
        defer { fts_close(walker) }
        var result: [(URL, stat)] = []
        while true {
            errno = 0
            guard let entry = fts_read(walker) else { break }
            try cancellation.check()
            let item = entry.pointee
            let hidden = item.fts_level > 0 && (item.fts_name == CChar(UInt8(ascii: ".")) || item.fts_statp.pointee.st_flags & UInt32(UF_HIDDEN) != 0)
            switch Int32(item.fts_info) {
            case FTS_D:
                guard item.fts_level > 0 else { continue }
                if hidden || (try? URL(fileURLWithPath: String(cString: item.fts_path), isDirectory: true).resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                    fts_set(walker, entry, FTS_SKIP)
                }
            case FTS_F:
                if !hidden { result.append((URL(fileURLWithPath: String(cString: item.fts_path), isDirectory: false), item.fts_statp.pointee)) }
            case FTS_DNR, FTS_ERR, FTS_NS:
                throw ImportError("Cannot list \(String(cString: item.fts_path)): \(String(cString: strerror(item.fts_errno)))")
            default: break
            }
        }
        guard errno == 0 else { throw ImportError("Cannot list \(root.path): \(String(cString: strerror(errno)))") }
        return result
    }
    func files(size: UInt64) -> [URL] { bySize[size] ?? [] }
    func match(source: URL, size: UInt64, fingerprint: String, hash: inout String?, cancellation: Cancellation, metrics: ReadMetrics? = nil) throws -> URL? {
        try matches(source: source, size: size, fingerprint: fingerprint, hash: &hash, all: false, cancellation: cancellation, metrics: metrics).first
    }
    private func storedHash(_ url: URL, info: stat, sample: String) -> String? {
        guard reuseCachedHashes, let cache = verificationCache, let namespace = cacheNamespace,
            let hash = cache.hash(for: url, namespace: namespace, info: info, sample: sample)
        else { return nil }
        cachedFiles.insert(url); return hash
    }
    private func rememberHash(_ url: URL, info: stat, sample: String, hash: String) {
        guard let cache = verificationCache, let namespace = cacheNamespace,
            let after = try? Importer.info(url), Importer.stable(info, after)
        else { return }
        cache.record(url, namespace: namespace, info: after, sample: sample, hash: hash)
    }
    /// Matching copies, sorted by path. Preview may reuse explicitly marked cache hints.
    /// Import constructs this index without a persistent cache, requiring complete reads.
    func matches(source: URL, size: UInt64, fingerprint: String, hash: inout String?, all: Bool, cancellation: Cancellation, metrics: ReadMetrics? = nil, sourceDevice: dev_t? = nil) throws -> [URL] {
        var found: [URL] = []
        if byFingerprint[size] == nil {
            var group: [String: [URL]] = [:]
            for url in bySize[size] ?? [] {
                try cancellation.check(); try Importer.assertDirectory(url.deletingLastPathComponent())
                let value = try Importer.fingerprint(url, cancellation: cancellation, metrics: metrics)
                samples[url] = (value.1, value.0)
                group[value.0, default: []].append(url)
            }
            byFingerprint[size] = group
        }
        for url in (byFingerprint[size]?[fingerprint] ?? []).sorted(by: { $0.path < $1.path }) {
            try cancellation.check()
            // Check current identity and samples even when a preview reuses a prior hash.
            try Importer.assertDirectory(url.deletingLastPathComponent())
            guard let current = try? Importer.info(url) else { continue }
            guard current.st_mode & S_IFMT == S_IFREG else { throw ImportError("Destination changed during scan. Scan again.") }
            let sample: String
            if let cached = samples[url], Importer.stable(cached.0, current) {
                sample = cached.1
            } else {
                let value = try Importer.fingerprint(url, cancellation: cancellation, metrics: metrics)
                sample = value.0; samples[url] = (value.1, sample)
            }
            guard sample == fingerprint else { continue }
            let sourceInfo = try Importer.info(source)
            if hash == nil { hash = storedHash(source, info: sourceInfo, sample: fingerprint) }
            let localHash = cache[url].flatMap { Importer.stable($0.0, current) ? $0.1 : nil }
            let cached = localHash ?? storedHash(url, info: current, sample: sample)
            let candidate: String
            if hash == nil, cached == nil, try (sourceDevice ?? Importer.info(source).st_dev) != current.st_dev {
                let pair = try Importer.digestPair(source, url, cancellation: cancellation, metrics: metrics)
                hash = pair.0; candidate = pair.1
                rememberHash(source, info: sourceInfo, sample: fingerprint, hash: pair.0)
                rememberHash(url, info: current, sample: sample, hash: candidate)
                cache[url] = (current, candidate)
            } else {
                if hash == nil {
                    hash = try Importer.digest(source, cancellation: cancellation, metrics: metrics).0
                    rememberHash(source, info: sourceInfo, sample: fingerprint, hash: hash!)
                }
                if let cached {
                    candidate = cached
                } else {
                    candidate = try Importer.digest(url, cancellation: cancellation, metrics: metrics).0
                    rememberHash(url, info: current, sample: sample, hash: candidate)
                    cache[url] = (current, candidate)
                }
            }
            if candidate == hash { found.append(url); if !all { break } }
        }
        return found
    }
    func add(_ url: URL, hash: String, size: UInt64, fingerprint: String) {
        bySize[size, default: []].append(url)
        if byFingerprint[size] != nil { byFingerprint[size]![fingerprint, default: []].append(url) }
        if let value = try? Importer.info(url) { cache[url] = (value, hash); samples[url] = (value, fingerprint) }
    }
}
