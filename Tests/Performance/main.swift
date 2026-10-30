import Foundation
import AppKit
import ImageIO
import CryptoKit
import Darwin

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw ImportError(message) }
}
func peakRSS() -> Int64 { var usage = rusage(); getrusage(RUSAGE_SELF, &usage); return Int64(usage.ru_maxrss) }
let mode = CommandLine.arguments[1]
let base = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
let thumbnailFile = base.appendingPathComponent("synthetic-4k.jpg")
if mode == "make-thumbnail" {
    let pixels = Data(repeating: 113, count: 4096 * 4096 * 4)
    let provider = CGDataProvider(data: pixels as CFData)!
    let image = CGImage(width: 4096, height: 4096, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4096 * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let writer = CGImageDestinationCreateWithURL(thumbnailFile as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(writer, image, nil)
    try require(CGImageDestinationFinalize(writer), "Could not generate synthetic JPEG")
    exit(0)
}
let root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
defer { try? FileManager.default.removeItem(at: root) }
let token = Cancellation(), source = root.appendingPathComponent("synthetic.NEF")
let fileBytes: Int64 = 64 * 1024 * 1024
var expected = ""
if mode != "thumbnails" {
    let fd = open(source.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    try require(fd >= 0, "Cannot create synthetic source")
    let buffer = Data(repeating: 123, count: 1024 * 1024)
    var hash = SHA256()
    for _ in 0..<64 {
        try buffer.withUnsafeBytes { bytes in
            try require(Darwin.write(fd, bytes.baseAddress, bytes.count) == bytes.count, "Cannot write synthetic source")
        }
        hash.update(data: buffer)
    }
    close(fd); expected = Importer.hex(hash.finalize())
}
let started = Date(), baseline = peakRSS()
var processed: Int64 = 0, progressUpdates = 0, maximumReadRequest = 0
// Deliberately one outer pool, as in a long-running background operation. Inner
// production pools must keep working even while this enclosing pool stays alive.
try autoreleasepool {
    switch mode {
    case "digest":
        for _ in 0..<16 {
            let result = try Importer.digest(source, cancellation: token)
            try require(result.0 == expected && result.1 == UInt64(fileBytes), "Digest changed original bytes")
            processed += fileBytes
        }
    case "paired-digest":
        let candidate = root.appendingPathComponent("synthetic-destination.NEF")
        try FileManager.default.copyItem(at: source, to: candidate)
        for _ in 0..<8 {
            let reads = ReadMetrics()
            let pair = try Importer.digestPair(source, candidate, cancellation: token, metrics: reads)
            try require(pair.0 == expected && pair.1 == expected && reads.hashedBytes == UInt64(fileBytes * 2), "Parallel hashing lost verification or read accounting")
            processed += fileBytes * 2
        }
    case "camera":
        let objects = (0..<8).map { CameraObject(id: String($0), folders: ["DCIM"], name: "SYNTH_\($0).NEF", size: fileBytes) }
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let snapshot = try CameraStaging.prepare(objects, camera: "synthetic://memory", cancellation: token, temporaryRoot: root,
            read: { _, offset, count in
                maximumReadRequest = max(maximumReadRequest, count)
                try input.seek(toOffset: UInt64(offset))
                return try input.read(upToCount: count) ?? Data()
            }, progress: { _ in progressUpdates += 1 })
        try require(snapshot.hashes.count == objects.count && snapshot.hashes.values.allSatisfy { $0 == expected }, "Camera transfer verification failed")
        try require(maximumReadRequest <= 4 * 1024 * 1024, "Camera transfer requested an oversized buffer")
        processed = fileBytes * Int64(objects.count)
    case "copy":
        let file = PlannedFile(source: source, role: .raw, group: 0, namedPrimary: nil, size: UInt64(fileBytes),
            fingerprint: "unused by stage", sourceInfo: try Importer.info(source), digest: expected, existing: nil, ownDate: nil, ownDateOrigin: nil)
        for _ in 0..<8 {
            let staged = try Importer.stage(file, in: root, cancellation: token)
            try require(staged.hash == expected, "Staged copy verification failed")
            try FileManager.default.removeItem(at: staged.staging)
            processed += fileBytes
        }
    case "cache":
        var now = Date()
        let cacheDirectory = root.appendingPathComponent("VerificationCache")
        let hints = DuplicateVerificationCache(directory: cacheDirectory, clock: { now })
        let info = try Importer.info(source), sample = try Importer.fingerprint(source, cancellation: token).0
        for index in 0..<30_000 {
            now = now.addingTimeInterval(1)
            hints.record(root.appendingPathComponent("original-\(index).NEF"), namespace: "synthetic-root", info: info, sample: sample, hash: expected)
            try require(hints.count <= DuplicateVerificationCache.maximumEntries, "Verification cache exceeded its entry bound")
        }
        hints.save()
        let reloaded = DuplicateVerificationCache(directory: cacheDirectory, clock: { now })
        try require(reloaded.count > 0 && reloaded.count <= DuplicateVerificationCache.maximumEntries, "Bounded cache did not reload")
        let cacheBytes = try Importer.info(hints.file).st_size
        try require(cacheBytes <= DuplicateVerificationCache.maximumBytes, "Verification cache exceeded its byte bound")
        processed = Int64(cacheBytes)
    case "thumbnails":
        for _ in 0..<128 {
            try autoreleasepool {
                guard let result = ThumbnailLoader.render(thumbnailFile) else { throw ImportError("Synthetic JPEG preview missing") }
                try require(max(result.image.size.width, result.image.size.height) <= 480, "Thumbnail dimensions exceed budget")
                try require(result.cost > 0 && result.cost <= 480 * 480 * 8, "Thumbnail storage cost exceeds budget")
            }
        }
        // A finished worker may still have a delivery queued on main. Cancellation
        // must clear its cache and suppress that obsolete delivery too.
        let loader = ThumbnailLoader()
        var staleDelivery = false
        let operation = loader.load(thumbnailFile, key: "old-source") { _ in staleDelivery = true }
        operation.waitUntilFinished()
        try require(loader.cached("old-source") != nil, "Thumbnail did not reach the cache")
        loader.cancelAll()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        try require(loader.cached("old-source") == nil && !staleDelivery, "Cancelled source retained or delivered its thumbnail")
        try require(loader.concurrency == 1, "Unbounded thumbnail decoder concurrency")
    default: throw ImportError("Unknown performance mode")
    }
    let peak = peakRSS(), growth = peak - baseline
    let report: [String: Any] = ["mode": mode, "processed_bytes": processed, "baseline_rss_bytes": baseline,
        "peak_rss_bytes": peak, "growth_bytes": growth, "elapsed_seconds": Date().timeIntervalSince(started),
        "progress_updates": progressUpdates, "maximum_read_request": maximumReadRequest]
    let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    print(String(decoding: json, as: UTF8.self))
    // A generous cross-machine guard catches accumulation of the 512 MiB / 1 GiB
    // workloads, without treating allocator noise or timing as a regression.
    try require(growth < 256 * 1024 * 1024, "Memory grew by 256 MiB or more during bounded streaming")
}
