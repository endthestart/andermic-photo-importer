import Foundation
import CryptoKit
import ImageIO
import Darwin

struct ImportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Settings: Codable {
    var destination = "/Volumes/Photography/Photo Container"
    var folderTemplate = "{YYYY}/{MM}-{DD} - {event}"
    var exiftool = "/opt/homebrew/bin/exiftool"
    var photoLab = "/Applications/DXOPhotoLab10.app"
    var openInDxO = false
    var eject = false
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Import", isDirectory: true)
    }
    static var url: URL { directory.appendingPathComponent("settings.json") }
    static func load() -> Settings {
        if let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(Settings.self, from: data) { return value }
        var value = Settings()
        if !FileManager.default.isExecutableFile(atPath: value.exiftool) {
            value.exiftool = ["/usr/local/bin/exiftool", "/usr/bin/exiftool"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? value.exiftool
        }
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: "/Applications")) ?? []
        if let app = apps.sorted().last(where: { $0.lowercased().contains("photolab") && $0.hasSuffix(".app") }) {
            value.photoLab = "/Applications/" + app
        }
        return value
    }
    func save() throws {
        try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: Self.url, options: .atomic)
    }
}

struct CaptureDay: Hashable, Codable, Comparable {
    let year: Int, month: Int, day: Int
    var text: String { String(format: "%04d-%02d-%02d", year, month, day) }
    static func < (lhs: CaptureDay, rhs: CaptureDay) -> Bool { lhs.text < rhs.text }
    static func parse(_ text: String) -> CaptureDay? {
        // Keep the camera's recorded calendar day; do not shift time zones.
        let prefix = String(text.prefix(10)).replacingOccurrences(of: ":", with: "-")
        let parts = prefix.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1900...2199).contains(parts[0]), (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = calendar.date(from: components) else { return nil }
        let result = calendar.dateComponents([.year, .month, .day], from: date)
        guard result.year == parts[0], result.month == parts[1], result.day == parts[2] else { return nil }
        return CaptureDay(year: parts[0], month: parts[1], day: parts[2])
    }
}

final class Cancellation {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    func check() throws {
        lock.lock(); let cancelled = value; lock.unlock()
        if cancelled { throw ImportError("Cancelled. Completed, verified copies are kept. You can safely scan again.") }
    }
}

struct PlannedFile {
    let source: URL, digest: String?, size: UInt64
    let date: CaptureDay?, folder: String?
    let existing: URL?
    let dateOrigin: String
    let fingerprint: String, sourceInfo: stat
}
struct ImportPlan {
    let source: URL, root: URL, settings: Settings, event: String
    let files: [PlannedFile]
    let ignored: Int
    let scanReads: ReadMetrics
    var newCount: Int { files.filter { $0.existing == nil }.count }
    var missingCount: Int { files.filter { $0.existing == nil && $0.date == nil }.count }
}
final class ReadMetrics {
    var sampledBytes: UInt64 = 0
    var hashedBytes: UInt64 = 0
}
struct ReceiptEntry: Codable {
    let source: String, destination: String, sha256: String, action: String, captureDate: String?, dateOrigin: String
}
struct Receipt: Codable {
    let started: Date
    var entries: [ReceiptEntry] = []
    var complete = false
    var error: String?
}
struct ImportResult {
    let copied: Int, skipped: Int
    let folders: [URL], receipt: URL
}

enum Importer {
    static let media: Set<String> = Set("nef nrw jpg jpeg jpe gpr dng cr2 cr3 crw arw srf sr2 raf orf rw2 raw rwl pef srw x3f erf mos mef iiq 3fr fff heic heif hif tif tiff png avif webp mov mp4 m4v mts m2ts avi".split(separator: " ").map(String.init))
    static let fm = FileManager.default

    static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
              !value.contains("/"), !value.contains("\\"), !value.contains(":"),
              value.utf8.count <= 220, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ImportError("Folder names must be 1–220 bytes and cannot start with a dot or contain /, \\, :, or control characters.")
        }
    }
    static func folder(template: String, event: String, date: CaptureDay) throws -> String {
        if template.contains("{event}") { try validateComponent(event) }
        var path = template
        let tokens = ["{YYYY}": String(format: "%04d", date.year), "{YY}": String(format: "%02d", date.year % 100),
                      "{MM}": String(format: "%02d", date.month), "{DD}": String(format: "%02d", date.day), "{event}": event]
        for (key, value) in tokens { path = path.replacingOccurrences(of: key, with: value) }
        guard !path.contains("{"), !path.contains("}") else { throw ImportError("Unknown folder token. Use {YYYY}, {YY}, {MM}, {DD}, or {event}.") }
        for part in path.components(separatedBy: "/") { try validateComponent(part) }
        return path
    }

    static func info(_ url: URL) throws -> stat {
        var result = stat()
        guard lstat(url.path, &result) == 0 else { throw ImportError("Cannot access \(url.path): \(String(cString: strerror(errno)))") }
        return result
    }
    static func assertDirectory(_ url: URL) throws {
        // Refuse symlinks in every path component, including an existing event directory.
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for part in url.standardizedFileURL.pathComponents.dropFirst() {
            current.appendPathComponent(part, isDirectory: true)
            let value = try info(current)
            guard value.st_mode & S_IFMT == S_IFDIR else { throw ImportError("Not a real directory (symlinks are refused): \(current.path)") }
        }
    }
    static func validateLocations(source: URL, root: URL) throws {
        try assertDirectory(source); try assertDirectory(root)
        let a = source.standardizedFileURL.path + "/", b = root.standardizedFileURL.path + "/"
        guard !a.hasPrefix(b), !b.hasPrefix(a) else { throw ImportError("The source and destination must be separate directories; neither may contain the other.") }
        guard fm.isWritableFile(atPath: root.path) else { throw ImportError("The destination is not writable: \(root.path)") }
    }

    static func files(in root: URL, allowed: Set<String>?, cancellation: Cancellation) throws -> ([URL], Int) {
        var result: [URL] = [], ignored = 0
        var enumerationError: Error?
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw ImportError("Cannot list \(root.path)")
        }
        for case let url as URL in walker {
            try cancellation.check()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true { walker.skipDescendants(); ignored += 1; continue }
            if values.isRegularFile == true {
                if allowed == nil || allowed!.contains(url.pathExtension.lowercased()) { result.append(url) } else { ignored += 1 }
            }
        }
        if let error = enumerationError { throw error }
        return (result.sorted { $0.path < $1.path }, ignored)
    }

    static func digest(_ url: URL, cancellation: Cancellation, metrics: ReadMetrics? = nil) throws -> (String, UInt64) {
        try cancellation.check()
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ImportError("Cannot read \(url.path)") }
        defer { close(fd) }
        var before = stat(); guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ImportError("Not a regular file: \(url.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        var hash = SHA256(), bytes: UInt64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try cancellation.check(); hash.update(data: data); bytes += UInt64(data.count)
            metrics?.hashedBytes += UInt64(data.count)
        }
        var after = stat(); guard fstat(fd, &after) == 0, stable(before, after), bytes == UInt64(before.st_size) else {
            throw ImportError("File changed while reading: \(url.path). Scan again.")
        }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
    static func stable(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    // A bounded sample only rejects candidates. Equality always requires a full SHA-256.
    static func fingerprint(_ url: URL, cancellation: Cancellation, metrics: ReadMetrics? = nil) throws -> (String, stat) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ImportError("Cannot read \(url.path)") }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0 else { throw ImportError("Not a regular file: \(url.path)") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let size = UInt64(before.st_size), chunk: UInt64 = 32 * 1024
        let offsets = Set([UInt64(0), size > chunk ? (size - chunk) / 2 : 0, size > chunk ? size - chunk : 0]).sorted()
        var hash = SHA256()
        for offset in offsets {
            try cancellation.check()
            try handle.seek(toOffset: offset)
            let count = Int(min(chunk, size - offset))
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ImportError("File changed while sampling. Scan again.") }
            hash.update(data: data); metrics?.sampledBytes += UInt64(data.count)
        }
        var after = stat()
        guard fstat(fd, &after) == 0, stable(before, after) else { throw ImportError("File changed while sampling. Scan again.") }
        return (hash.finalize().map { String(format: "%02x", $0) }.joined(), after)
    }

    static func dates(_ urls: [URL], tool: String, cancellation: Cancellation) throws -> [String: (CaptureDay, String)] {
        guard fm.isExecutableFile(atPath: tool) else { throw ImportError("ExifTool is required. Install it, then choose its executable in Settings. See the setup guide.") }
        var result: [String: (CaptureDay, String)] = [:]
        for start in stride(from: 0, to: urls.count, by: 80) {
            try cancellation.check()
            let batch = Array(urls[start..<min(start + 80, urls.count)])
            let temporary = fm.temporaryDirectory.appendingPathComponent("photo-import-metadata-" + UUID().uuidString)
            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: temporary) }
            let outputURL = temporary.appendingPathComponent("out.json"), errorsURL = temporary.appendingPathComponent("err.txt")
            fm.createFile(atPath: outputURL.path, contents: nil); fm.createFile(atPath: errorsURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: outputURL), err = try FileHandle(forWritingTo: errorsURL)
            defer { try? out.close(); try? err.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: tool)
            // Disable user ExifTool configuration; arguments are never passed through a shell.
            process.arguments = ["-config", "", "-j", "-G1", "-a", "-DateTimeOriginal", "-SubSecDateTimeOriginal", "-CreateDate", "-CreationDate", "--"] + batch.map(\.path)
            process.standardOutput = out; process.standardError = err
            try process.run()
            let deadline = Date().addingTimeInterval(120)
            while process.isRunning {
                do { try cancellation.check() } catch { process.terminate(); process.waitUntilExit(); throw error }
                if Date() > deadline { process.terminate(); process.waitUntilExit(); throw ImportError("Metadata reading timed out. No photos have been copied.") }
                Thread.sleep(forTimeInterval: 0.1)
            }
            // Per-file errors (exit 1) appear in JSON and become missing-date entries.
            guard process.terminationReason == .exit, process.terminationStatus == 0 || process.terminationStatus == 1,
                  let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) as? [[String: Any]] else {
                throw ImportError("ExifTool could not read the card. Check the source and ExifTool path.")
            }
            for row in rows {
                guard let source = row["SourceFile"] as? String else { continue }
                let preferred = ["ExifIFD:DateTimeOriginal", "Composite:SubSecDateTimeOriginal", "XMP-exif:DateTimeOriginal",
                                 "Keys:CreationDate", "QuickTime:CreationDate", "ExifIFD:CreateDate", "XMP-xmp:CreateDate", "QuickTime:CreateDate"]
                let keys = preferred + row.keys.sorted().filter { key in
                    !preferred.contains(key) && ["DateTimeOriginal", "SubSecDateTimeOriginal", "CreateDate", "CreationDate"].contains(String(key.split(separator: ":").last ?? ""))
                }
                for key in keys {
                    if let raw = row[key] as? String, let day = CaptureDay.parse(raw) { result[source] = (day, key); break }
                }
            }
        }
        return result
    }

    static func captureDates(_ urls: [URL], tool: String, cancellation: Cancellation) throws -> [String: (CaptureDay, String)] {
        var result: [String: (CaptureDay, String)] = [:], unresolved: [URL] = []
        // ImageIO reads the standard original-capture field without decoding image pixels.
        // Other dates and unsupported containers retain the complete ExifTool fallback.
        for url in urls {
            try cancellation.check()
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard fd >= 0 else { throw ImportError("Cannot read \(url.path)") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var before = stat(), after = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ImportError("Not a regular file: \(url.path)") }
            let header = try handle.read(upToCount: 256 * 1024) ?? Data()
            guard fstat(fd, &after) == 0, stable(before, after) else { throw ImportError("Source changed while reading capture dates. Scan again.") }
            try handle.close()
            if let image = CGImageSourceCreateWithData(header as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
               let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
               let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
               let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let day = CaptureDay.parse(text) {
                result[url.path] = (day, "ExifIFD:DateTimeOriginal")
            } else { unresolved.append(url) }
        }
        if !unresolved.isEmpty { result.merge(try dates(unresolved, tool: tool, cancellation: cancellation)) { first, _ in first } }
        return result
    }

    static func plan(source: URL, settings: Settings, event: String, fallback: CaptureDay?, cancellation: Cancellation,
                     progress: (String) -> Void) throws -> ImportPlan {
        let root = URL(fileURLWithPath: settings.destination, isDirectory: true).standardizedFileURL
        try validateLocations(source: source, root: root)
        _ = try folder(template: settings.folderTemplate, event: event, date: CaptureDay(year: 2026, month: 10, day: 4))
        progress("Reading capture dates…")
        let (all, ignored) = try files(in: source, allowed: media, cancellation: cancellation)
        guard !all.isEmpty else { throw ImportError("No supported photos or videos were found in this source.") }
        let metadataVersions = try Dictionary(uniqueKeysWithValues: all.map { ($0, try info($0)) })
        let metadata = try captureDates(all, tool: settings.exiftool, cancellation: cancellation)
        progress("Checking the destination library for already imported files…")
        let library = try LibraryIndex(root: root, cancellation: cancellation)
        var planned: [PlannedFile] = []
        var seen: [String: [URL]] = [:]
        let metrics = ReadMetrics()
        for (i, url) in all.enumerated() {
            progress("Checking file \(i + 1) of \(all.count): \(url.lastPathComponent)")
            let (sample, version) = try fingerprint(url, cancellation: cancellation, metrics: metrics)
            // Filesystem metadata updates can change ctime during metadata discovery.
            // The preview snapshot below retains ctime for strict import-time checks.
            guard let metadataVersion = metadataVersions[url], metadataVersion.st_dev == version.st_dev,
                  metadataVersion.st_ino == version.st_ino, metadataVersion.st_size == version.st_size,
                  metadataVersion.st_mtimespec.tv_sec == version.st_mtimespec.tv_sec,
                  metadataVersion.st_mtimespec.tv_nsec == version.st_mtimespec.tv_nsec else {
                throw ImportError("\(url.lastPathComponent) changed while reading capture dates. Scan again.")
            }
            let size = UInt64(version.st_size), key = "\(size):\(sample)"
            var hash: String?
            var existing = try library.match(source: url, size: size, fingerprint: sample, hash: &hash, cancellation: cancellation, metrics: metrics)
            if existing == nil {
                for peer in seen[key] ?? [] {
                    if hash == nil { hash = try digest(url, cancellation: cancellation, metrics: metrics).0 }
                    if try digest(peer, cancellation: cancellation, metrics: metrics).0 == hash { existing = peer; break }
                }
            }
            guard stable(version, try info(url)) else { throw ImportError("Source changed during preview. Scan again.") }
            let date = metadata[url.path]?.0 ?? fallback
            let subfolder = try date.map { try folder(template: settings.folderTemplate, event: event, date: $0) }
            planned.append(PlannedFile(source: url, digest: hash, size: size, date: date, folder: subfolder, existing: existing,
                                       dateOrigin: metadata[url.path]?.1 ?? (fallback == nil ? "missing" : "user-selected date"), fingerprint: sample, sourceInfo: version))
            seen[key, default: []].append(url)
        }
        return ImportPlan(source: source, root: root, settings: settings, event: event, files: planned, ignored: ignored, scanReads: metrics)
    }

    static func makeFolder(root: URL, relative: String) throws -> URL {
        try assertDirectory(root)
        var directory = root
        for component in relative.components(separatedBy: "/") {
            try validateComponent(component)
            directory.appendPathComponent(component, isDirectory: true)
            if mkdir(directory.path, 0o755) != 0 && errno != EEXIST { throw ImportError("Cannot create \(directory.path): \(String(cString: strerror(errno)))") }
            try assertDirectory(directory)
        }
        return directory
    }

    static func verifiedCopy(_ file: PlannedFile, to directory: URL, cancellation: Cancellation) throws -> (URL, Bool, String) {
        try assertDirectory(directory)
        let staging = directory.appendingPathComponent(".photo-import-" + UUID().uuidString + ".partial")
        let outputFD = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw ImportError("Cannot write to \(directory.path)") }
        defer { close(outputFD); try? fm.removeItem(at: staging) }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)
        let inputFD = open(file.source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard inputFD >= 0 else { throw ImportError("Cannot read \(file.source.path)") }
        defer { close(inputFD) }
        var before = stat(); guard fstat(inputFD, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ImportError("Source is not a regular file.") }
        guard stable(file.sourceInfo, before) else { throw ImportError("Source changed since the preview. Scan again.") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
        var hash = SHA256(), bytes: UInt64 = 0
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
            try cancellation.check(); try output.write(contentsOf: data); hash.update(data: data); bytes += UInt64(data.count)
        }
        var after = stat()
        let copiedHash = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard fstat(inputFD, &after) == 0, stable(before, after), bytes == file.size, file.digest == nil || copiedHash == file.digest else {
            throw ImportError("\(file.source.lastPathComponent) changed since the preview. Scan again; it was not imported.")
        }
        guard fsync(outputFD) == 0 else { throw ImportError("Could not flush the copied file to disk.") }
        let (readBack, readSize) = try digest(staging, cancellation: cancellation)
        guard readBack == copiedHash, readSize == file.size else { throw ImportError("Copy verification failed for \(file.source.lastPathComponent). The card will not be ejected.") }
        // Preserve file timestamps after verification. The source bytes and embedded metadata are untouched.
        var times = [before.st_atimespec, before.st_mtimespec]
        guard futimens(outputFD, &times) == 0, fchmod(outputFD, 0o644) == 0, fsync(outputFD) == 0 else { throw ImportError("Could not finalize the verified copy.") }
        var name = file.source.lastPathComponent
        let ext = file.source.pathExtension
        let base = file.source.deletingPathExtension().lastPathComponent
        for attempt in 0..<10000 {
            try cancellation.check(); try assertDirectory(directory)
            let target = directory.appendingPathComponent(name)
            // macOS exclusive rename publishes without overwriting, even when a filename races.
            if renamex_np(staging.path, target.path, UInt32(RENAME_EXCL)) == 0 {
                let directoryFD = open(directory.path, O_RDONLY | O_NOFOLLOW)
                guard directoryFD >= 0 else { throw ImportError("Cannot flush the destination folder.") }
                defer { close(directoryFD) }
                guard fsync(directoryFD) == 0 else { throw ImportError("The copy is verified, but the folder could not be flushed. Keep the card inserted.") }
                return (target, true, copiedHash)
            }
            guard errno == EEXIST else { throw ImportError("Cannot publish the verified copy: \(String(cString: strerror(errno))). This destination must support macOS exclusive rename; no unsafe overwrite fallback is used.") }
            let existing = try info(target)
            if existing.st_mode & S_IFMT == S_IFREG {
                let (existingHash, _) = try digest(target, cancellation: cancellation)
                if existingHash == copiedHash { return (target, false, copiedHash) }
            }
            // A different same-name file gets a stable hash suffix; no existing file is overwritten.
            var shortened = base
            while shortened.utf8.count > 140 { shortened.removeLast() }
            name = shortened + "__" + String(copiedHash.prefix(16)) + (attempt == 0 ? "" : "-\(attempt)") + (ext.isEmpty ? "" : "." + ext)
        }
        throw ImportError("Too many filename collisions for \(file.source.lastPathComponent).")
    }

    static func run(_ plan: ImportPlan, cancellation: Cancellation, reportDirectory: URL? = nil, progress: (String) -> Void) throws -> ImportResult {
        try validateLocations(source: plan.source, root: plan.root)
        guard plan.missingCount == 0 else { throw ImportError("Choose a fallback date for files without capture metadata, then scan again.") }
        let lockURL = plan.root.appendingPathComponent(".photo-import.lock")
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else { throw ImportError("Cannot lock this destination.") }
        defer { close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw ImportError("Another import is using this destination. Wait for it to finish.")
        }
        defer { flock(lockFD, LOCK_UN) }
        let logs = reportDirectory ?? Settings.directory.appendingPathComponent("Reports", isDirectory: true)
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let receiptURL = logs.appendingPathComponent(UUID().uuidString + ".json")
        var receipt = Receipt(started: Date())
        func saveReceipt() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        }
        try saveReceipt()
        var copied = 0, skipped = 0, folders = Set<URL>()
        do {
            progress("Rechecking the destination before copying…")
            let library = try LibraryIndex(root: plan.root, cancellation: cancellation)
            for (i, file) in plan.files.enumerated() {
                try cancellation.check(); try assertDirectory(plan.root)
                progress("Importing \(i + 1) of \(plan.files.count): \(file.source.lastPathComponent)")
                guard stable(file.sourceInfo, try info(file.source)) else { throw ImportError("Source changed since the preview. Scan again.") }
                let target: URL, isNew: Bool, verifiedHash: String
                // Rehash candidates at import time; preview samples are never proof for a skip.
                var hash: String?
                if let match = try library.match(source: file.source, size: file.size, fingerprint: file.fingerprint, hash: &hash, cancellation: cancellation) {
                    guard let confirmed = hash, file.digest == nil || confirmed == file.digest,
                          stable(file.sourceInfo, try info(file.source)) else { throw ImportError("Source changed since the preview. Scan again.") }
                    target = match; isNew = false
                    verifiedHash = confirmed
                } else {
                    guard let folder = file.folder else { throw ImportError("An already imported file disappeared and has no capture date. Scan again.") }
                    let directory = try makeFolder(root: plan.root, relative: folder)
                    (target, isNew, verifiedHash) = try verifiedCopy(file, to: directory, cancellation: cancellation)
                    library.add(target, hash: verifiedHash, size: file.size, fingerprint: file.fingerprint)
                }
                if isNew { copied += 1; folders.insert(target.deletingLastPathComponent()) } else { skipped += 1 }
                receipt.entries.append(ReceiptEntry(source: file.source.path, destination: target.path, sha256: verifiedHash,
                                                     action: isNew ? "copied and verified" : "already imported and verified", captureDate: file.date?.text, dateOrigin: file.dateOrigin))
                try saveReceipt()
            }
            try cancellation.check()
            // Re-read every final destination before allowing optional ejection.
            for entry in receipt.entries {
                progress("Final verification: \(URL(fileURLWithPath: entry.destination).lastPathComponent)")
                try assertDirectory(URL(fileURLWithPath: entry.destination).deletingLastPathComponent())
                let (hash, _) = try digest(URL(fileURLWithPath: entry.destination), cancellation: cancellation)
                guard hash == entry.sha256 else { throw ImportError("Final verification failed. Keep the card inserted and scan again.") }
            }
            receipt.complete = true; try saveReceipt()
        } catch {
            receipt.error = error.localizedDescription; try? saveReceipt()
            throw ImportError("\(error.localizedDescription)\n\n\(copied) verified copies completed. The card has not been ejected. Report: \(receiptURL.path)")
        }
        return ImportResult(copied: copied, skipped: skipped, folders: folders.sorted { $0.path < $1.path }, receipt: receiptURL)
    }
}

final class LibraryIndex {
    private var bySize: [UInt64: [URL]] = [:]
    private var byFingerprint: [UInt64: [String: [URL]]] = [:]
    private var cache: [URL: (stat, String)] = [:]
    private var samples: [URL: (stat, String)] = [:]
    init(root: URL, cancellation: Cancellation) throws {
        // No persistent catalog: inspect all regular files, including files renamed to unknown extensions.
        let (files, _) = try Importer.files(in: root, allowed: nil, cancellation: cancellation)
        for url in files {
            try cancellation.check()
            let value = try Importer.info(url)
            guard value.st_mode & S_IFMT == S_IFREG else { continue }
            bySize[UInt64(value.st_size), default: []].append(url)
        }
    }
    func match(source: URL, size: UInt64, fingerprint: String, hash: inout String?, cancellation: Cancellation, metrics: ReadMetrics? = nil) throws -> URL? {
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
        for url in byFingerprint[size]?[fingerprint] ?? [] {
            try cancellation.check()
            // Each match is read again, so deleted or modified duplicates cannot cause unsafe skips.
            try Importer.assertDirectory(url.deletingLastPathComponent())
            let current = try Importer.info(url)
            guard current.st_mode & S_IFMT == S_IFREG else { throw ImportError("Destination changed during scan. Scan again.") }
            let sample: String
            if let cached = samples[url], Importer.stable(cached.0, current) { sample = cached.1 }
            else {
                let value = try Importer.fingerprint(url, cancellation: cancellation, metrics: metrics)
                sample = value.0; samples[url] = (value.1, sample)
            }
            guard sample == fingerprint else { continue }
            if hash == nil { hash = try Importer.digest(source, cancellation: cancellation, metrics: metrics).0 }
            let candidate: String
            if let cached = cache[url], Importer.stable(cached.0, current) { candidate = cached.1 }
            else {
                candidate = try Importer.digest(url, cancellation: cancellation, metrics: metrics).0
                cache[url] = (current, candidate)
            }
            if candidate == hash { return url }
        }
        return nil
    }
    func add(_ url: URL, hash: String, size: UInt64, fingerprint: String) {
        bySize[size, default: []].append(url)
        if byFingerprint[size] != nil { byFingerprint[size]![fingerprint, default: []].append(url) }
        if let value = try? Importer.info(url) { cache[url] = (value, hash); samples[url] = (value, fingerprint) }
    }
}
