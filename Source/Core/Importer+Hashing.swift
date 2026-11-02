import CryptoKit
import Darwin
import Foundation

extension Importer {
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }

    static func digest(_ url: URL, cancellation: Cancellation, metrics: ReadMetrics? = nil) throws -> (String, UInt64) {
        try cancellation.check()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ImportError("Cannot read \(url.path)") }
        defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ImportError("Not a regular file: \(url.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256(), bytes: UInt64 = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            try cancellation.check()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            hash.update(data: data); bytes += UInt64(data.count)
            metrics?.hashedBytes += UInt64(data.count)
            return true
        }) {}
        var after = stat();
        guard fstat(fd, &after) == 0, stable(before, after), bytes == UInt64(before.st_size) else {
            throw ImportError("File changed while reading: \(url.path). Scan again.")
        }
        return (hex(hash.finalize()), bytes)
    }
    private final class DigestReply {
        private let lock = NSLock()
        private var result: Result<(String, UInt64), Error>?
        func store(_ value: Result<(String, UInt64), Error>) { lock.lock(); result = value; lock.unlock() }
        func get() throws -> (String, UInt64) {
            lock.lock(); let value = result; lock.unlock()
            guard let value else { throw ImportError("Parallel verification did not finish.") }
            return try value.get()
        }
    }

    /// Compare originals on independent volumes without serializing both full
    /// reads. There is only one additional reader, and each hash keeps its own
    /// counters and per-buffer pool. No sample or cached preview authorizes a skip.
    static func digestPair(
        _ source: URL, _ candidate: URL, cancellation: Cancellation,
        metrics: ReadMetrics? = nil
    ) throws -> (String, String) {
        try cancellation.check()
        let reply = DigestReply(), finished = DispatchGroup()
        let sourceReads = ReadMetrics(), candidateReads = ReadMetrics()
        finished.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.leave() }
            reply.store(Result { try autoreleasepool { try digest(candidate, cancellation: cancellation, metrics: candidateReads) } })
        }
        let sourceResult = Result { try digest(source, cancellation: cancellation, metrics: sourceReads) }
        finished.wait()
        metrics?.hashedBytes += sourceReads.hashedBytes + candidateReads.hashedBytes
        let left = try sourceResult.get(), right = try reply.get()
        return (left.0, right.0)
    }

    static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    // A sample rejects candidates or validates an unchanged-file cache record;
    // it cannot independently establish byte equality.
    static func fingerprint(_ url: URL, cancellation: Cancellation, metrics: ReadMetrics? = nil) throws -> (String, stat) {
        var hash = SHA256()
        let version = try samples(url, cancellation: cancellation, metrics: metrics) { hash.update(data: $0) }
        return (hex(hash.finalize()), version)
    }

    /// Separate hashes of the first, middle, and last samples (fewer for small files).
    static func sampleParts(_ url: URL, cancellation: Cancellation, metrics: ReadMetrics? = nil) throws -> ([String], stat) {
        var parts: [String] = []
        let version = try samples(url, cancellation: cancellation, metrics: metrics) { parts.append(hex(SHA256.hash(data: $0))) }
        return (parts, version)
    }

    /// Reads up to three 32 KiB samples in offset order, failing if the file changes meanwhile.
    private static func samples(_ url: URL, cancellation: Cancellation, metrics: ReadMetrics?, each: (Data) -> Void) throws -> stat {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ImportError("Cannot read \(url.path)") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw ImportError("Not a regular file: \(url.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let size = UInt64(before.st_size), chunk: UInt64 = 32 * 1024
        let offsets = Set([UInt64(0), size > chunk ? (size - chunk) / 2 : 0, size > chunk ? size - chunk : 0]).sorted()
        for offset in offsets {
            try autoreleasepool {
                try cancellation.check()
                try handle.seek(toOffset: offset)
                let count = Int(min(chunk, size - offset))
                let data = try handle.read(upToCount: count) ?? Data()
                guard data.count == count else { throw ImportError("File changed while sampling. Scan again.") }
                each(data); metrics?.sampledBytes += UInt64(data.count)
            }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, stable(before, after) else { throw ImportError("File changed while sampling. Scan again.") }
        return after
    }
}
