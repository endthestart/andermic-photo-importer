import CryptoKit
import Darwin
import Foundation
import ImageIO

extension Importer {
    /// Runs the bundled ExifTool over `urls` in batches of 80 and hands each JSON row to `each`,
    /// so callers can reduce rows as they arrive. Arguments are never passed through a shell.
    static func exifToolRows(
        _ urls: [URL], options: [String], helper: MetadataHelper, cancellation: Cancellation,
        each: ([String: Any]) throws -> Void
    ) throws {
        try helper.validate()
        for start in stride(from: 0, to: urls.count, by: 80) {
            try autoreleasepool {
                try cancellation.check()
                let batch = Array(urls[start..<min(start + 80, urls.count)])
                let temporary = fm.temporaryDirectory.appendingPathComponent("photo-import-metadata-" + UUID().uuidString)
                try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: temporary) }
                let outputURL = temporary.appendingPathComponent("out.json"), errorsURL = temporary.appendingPathComponent("err.txt")
                fm.createFile(atPath: outputURL.path, contents: nil); fm.createFile(atPath: errorsURL.path, contents: nil)
                let out = try FileHandle(forWritingTo: outputURL), err = try FileHandle(forWritingTo: errorsURL)
                defer { try? out.close(); try? err.close() }
                // Arguments are never passed through a shell.
                let process = helper.process(arguments: options + ["--"] + batch.map(\.path))
                process.standardOutput = out; process.standardError = err
                try process.run()
                let deadline = Date().addingTimeInterval(120)
                while process.isRunning {
                    do { try cancellation.check() } catch { process.terminate(); process.waitUntilExit(); throw error }
                    if Date() > deadline { process.terminate(); process.waitUntilExit(); throw ImportError("Metadata reading timed out. No photos have been copied.") }
                    Thread.sleep(forTimeInterval: 0.05)
                }
                // Per-file errors (exit 1) appear in JSON and become missing-date entries.
                guard process.terminationReason == .exit, process.terminationStatus == 0 || process.terminationStatus == 1,
                    let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) as? [[String: Any]]
                else {
                    throw ImportError("The built-in metadata reader could not read this source. No photos have been copied.")
                }
                for row in rows { try each(row) }
            }
        }
    }

    /// Complete metadata fallback using the bundled ExifTool.
    static func dates(_ urls: [URL], helper: MetadataHelper, cancellation: Cancellation) throws -> [String: (CaptureDay, String)] {
        var result: [String: (CaptureDay, String)] = [:]
        try exifToolRows(
            urls, options: ["-j", "-G1", "-a", "-DateTimeOriginal", "-SubSecDateTimeOriginal", "-CreateDate", "-CreationDate"],
            helper: helper, cancellation: cancellation
        ) { row in
            guard let source = row["SourceFile"] as? String else { return }
            let preferred = [
                "ExifIFD:DateTimeOriginal", "Composite:SubSecDateTimeOriginal", "XMP-exif:DateTimeOriginal",
                "Keys:CreationDate", "QuickTime:CreationDate", "ExifIFD:CreateDate", "XMP-xmp:CreateDate", "QuickTime:CreateDate",
            ]
            let keys =
                preferred
                + row.keys.sorted().filter { key in
                    !preferred.contains(key) && ["DateTimeOriginal", "SubSecDateTimeOriginal", "CreateDate", "CreationDate"].contains(String(key.split(separator: ":").last ?? ""))
                }
            for key in keys {
                if let raw = row[key] as? String, let day = CaptureDay.parse(raw) { result[source] = (day, key); break }
            }
        }
        return result
    }

    static func captureDates(
        _ urls: [URL], helper: MetadataHelper, cancellation: Cancellation, metrics: ReadMetrics? = nil,
        progress: (Int) -> Void = { _ in }
    ) throws -> [String: (CaptureDay, String)] {
        var result: [String: (CaptureDay, String)] = [:], unresolved: [URL] = []
        // ImageIO reads the standard original-capture field from a bounded header without
        // decoding pixels. Other dates and unsupported containers use the bundled ExifTool.
        for (index, url) in urls.enumerated() {
            try autoreleasepool {
                try cancellation.check(); progress(index)
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                guard fd >= 0 else { throw ImportError("Cannot read \(url.path)") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var before = stat(), after = stat()
                guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ImportError("Not a regular file: \(url.path)") }
                let header = try handle.read(upToCount: 256 * 1024) ?? Data()
                metrics?.headerBytes += UInt64(header.count)
                guard fstat(fd, &after) == 0, stable(before, after) else { throw ImportError("Source changed while reading capture dates. Scan again.") }
                try handle.close()
                if let image = CGImageSourceCreateWithData(header as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                    let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
                    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
                    let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let day = CaptureDay.parse(text)
                {
                    result[url.path] = (day, "ExifIFD:DateTimeOriginal")
                } else {
                    unresolved.append(url)
                }
            }
        }
        if !unresolved.isEmpty { result.merge(try dates(unresolved, helper: helper, cancellation: cancellation)) { first, _ in first } }
        return result
    }

    /// Card-slot fields a camera writes differently to each card when recording to both.
    static let cardSlotTags: Set<String> = ["MemoryCardNumber", "BurstStartSlotNumber"]

    /// A digest of everything ExifTool reports except file-system values and card-slot fields,
    /// or nil unless the row names a camera serial number and an original capture time.
    static func shotIdentity(_ row: [String: Any]) -> String? {
        guard row["Error"] == nil else { return nil }
        var lines: [String] = [], serial = false, captured = false
        for (key, value) in row {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, !["System", "File", "ExifTool", "Composite"].contains(parts[0]), !cardSlotTags.contains(parts[1]) else { continue }
            guard let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys]) else { return nil }
            let text = String(decoding: data, as: UTF8.self)
            let present = text != "[\"\"]" && text != "[null]"
            if parts[1] == "SerialNumber" && present { serial = true }
            if parts[1] == "DateTimeOriginal" && present { captured = true }
            lines.append(key + "\u{0}" + text)
        }
        guard serial, captured else { return nil }
        return hex(SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)))
    }

    /// ADR-0014. Marks photos and videos with no byte-identical copy as imported when a destination
    /// file has the same name and size, the same middle and last samples, and the same camera
    /// metadata apart from card-slot fields. Groups with sidecars keep the byte-equality rules.
    static func recognizeOtherCardCopies(
        _ files: inout [PlannedFile], groups: inout [PhotoGroup], library: LibraryIndex, root: URL, source: URL,
        helper: MetadataHelper, cancellation: Cancellation, metrics: ReadMetrics,
        progress: (ImportProgress) -> Void
    ) throws {
        var pairs: [(index: Int, target: URL, samples: [String])] = []
        for group in groups where group.members.allSatisfy({ files[$0].role != .sidecar }) {
            for index in group.members where files[index].existing == nil {
                try autoreleasepool {
                    let file = files[index], name = file.source.lastPathComponent.lowercased()
                    let candidates = library.files(size: file.size)
                        .filter { $0.lastPathComponent.lowercased() == name && $0.path.hasPrefix(root.path + "/") }.sorted { $0.path < $1.path }
                    guard !candidates.isEmpty else { return }
                    let (sourceParts, version) = try sampleParts(file.source, cancellation: cancellation, metrics: metrics)
                    guard stable(file.sourceInfo, version) else { throw ImportError("Source changed during preview. Scan again.") }
                    for candidate in candidates {
                        try assertDirectory(candidate.deletingLastPathComponent())
                        let (parts, value) = try sampleParts(candidate, cancellation: cancellation, metrics: metrics)
                        if UInt64(value.st_size) == file.size, parts.dropFirst() == sourceParts.dropFirst() {
                            pairs.append((index, candidate, Array(sourceParts.dropFirst())))
                        }
                    }
                }
            }
        }
        guard !pairs.isEmpty else { return }
        progress(ImportProgress("Comparing \(pairs.count) possible copies from the camera's other card…"))
        let urls = Array(Set(pairs.flatMap { [files[$0.index].source, $0.target] })).sorted { $0.path < $1.path }
        var identities: [String: String] = [:]
        try exifToolRows(urls, options: ["-j", "-G1", "-a", "-n", "-fast"], helper: helper, cancellation: cancellation) { row in
            if let path = row["SourceFile"] as? String, let identity = shotIdentity(row) { identities[path] = identity }
        }
        for pair in pairs where files[pair.index].existing == nil {
            guard let left = identities[files[pair.index].source.path], left == identities[pair.target.path] else { continue }
            files[pair.index].existing = pair.target; files[pair.index].otherCardCopy = true; files[pair.index].otherCardSamples = pair.samples
        }
        for index in groups.indices { groups[index].status = status(groups[index].members.map { files[$0] }, source: source) }
    }
}
