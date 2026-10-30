import Foundation
import CryptoKit
import ImageIO
import Darwin

struct ImportError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// An import that stopped early. Verified copies listed in `outcomes` remain in place.
struct ImportFailure: LocalizedError {
    let message: String
    let copied: Int, skipped: Int
    let outcomes: [String: URL]
    let receipt: URL
    let cancelled: Bool
    var errorDescription: String? { message }
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
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func check() throws {
        if isCancelled { throw ImportError("Cancelled. Completed, verified copies are kept. You can safely scan again.") }
    }
}

struct ImportProgress {
    let text: String
    let fraction: Double?
    init(_ text: String, fraction: Double? = nil) { self.text = text; self.fraction = fraction }
}

struct PlannedFile {
    let source: URL
    let role: FileRole
    let group: Int
    /// For a sidecar named after a complete filename (`A.NEF.xmp`), the photo it names.
    let namedPrimary: URL?
    let size: UInt64
    let fingerprint: String
    let sourceInfo: stat
    var digest: String?
    /// A content-confirmed copy in the destination, or an identical earlier file in this source.
    var existing: URL?
    let ownDate: CaptureDay?
    var ownDateOrigin: String?
    var date: CaptureDay? = nil
    var folder: String? = nil
    var dateOrigin = "missing"
    /// Set when the file will be placed beside an already imported photo instead of in the date folder.
    var besideDirectory: URL? = nil
    /// A photo copied again only so that a changed sidecar keeps a matching photo (see `resolveSidecars`).
    var companion = false
    /// Cached recognition; selected files are fully rechecked during import.
    var cachedVerification = false
    var cachedCaptureMetadata = false
}

enum GroupStatus: String {
    case new, partial, imported, sidecarChanged, sourceDuplicate
}

struct PhotoGroup {
    let id: Int
    let name: String
    let directory: URL
    let members: [Int]
    var date: CaptureDay?
    var dateOrigin: String
    var folder: String?
    var status: GroupStatus
    /// New photo content is selected for import by default; sidecar-only differences are not.
    var isNew: Bool { status == .new || status == .partial }
}

final class ReadMetrics {
    var headerBytes: UInt64 = 0
    var sampledBytes: UInt64 = 0
    var hashedBytes: UInt64 = 0
    var cachedCaptureDates = 0
    var total: UInt64 { headerBytes + sampledBytes + hashedBytes }
}

struct ImportPlan {
    let source: URL, root: URL
    var settings: Settings
    var event: String
    var fallback: CaptureDay?
    var files: [PlannedFile]
    var groups: [PhotoGroup]
    let ignored: Int
    let orphanSidecars: [URL]
    let scanReads: ReadMetrics
    // USB originals are read into a private snapshot. Reports retain camera provenance.
    var sourceDescription: String? = nil
    var sourceFileDescriptions: [String: String] = [:]

    func describedSource(_ file: URL) -> String { sourceFileDescriptions[file.path] ?? file.path }

    var cachedGroups: Int { groups.filter { members($0).contains(where: \.cachedVerification) }.count }

    var newCount: Int { files.filter { $0.existing == nil }.count }
    /// Files an import would copy: new files and files whose only match is elsewhere in this source.
    func needsCopy(_ file: PlannedFile) -> Bool { file.companion || (file.existing.map { $0.path.hasPrefix(source.path + "/") } ?? true) }
    /// Files that need a capture day: those copied into a date folder rather than beside an imported photo.
    func needsDate(_ file: PlannedFile) -> Bool { needsCopy(file) && file.besideDirectory == nil && file.date == nil }
    var missingCount: Int { files.filter(needsDate).count }
    var newGroups: Set<Int> { Set(groups.filter(\.isNew).map(\.id)) }
    /// New groups that can be organized now. Undated groups wait for an explicit fallback date.
    var importableNewGroups: Set<Int> { newGroups.filter { missingDates(in: [$0]) == 0 } }
    func members(_ group: PhotoGroup) -> [PlannedFile] { group.members.map { files[$0] } }
    func missingDates(in selection: Set<Int>) -> Int {
        selection.reduce(0) { count, id in count + members(groups[id]).filter(needsDate).count }
    }
    func bytes(in selection: Set<Int>, newOnly: Bool = true) -> UInt64 {
        selection.reduce(0) { total, id in total + members(groups[id]).filter { !newOnly || needsCopy($0) }.reduce(0) { $0 + $1.size } }
    }
    func fileCount(in selection: Set<Int>) -> Int { selection.reduce(0) { $0 + groups[$1].members.count } }

    /// Recompute dates and folders for a new template, event name, or fallback date.
    /// This reads no files; duplicate status is unchanged.
    func organized(template: String, event: String, fallback: CaptureDay?) throws -> ImportPlan {
        var value = self
        value.settings.folderTemplate = template; value.event = event; value.fallback = fallback
        _ = try Importer.folder(template: template, event: event, date: CaptureDay(year: 2026, month: 10, day: 4))
        for index in value.groups.indices {
            let group = value.groups[index]
            // The group's day comes from its highest-priority dated photo (RAW, then image, then
            // video) so related files stay together. Sidecars and undated members inherit it.
            let dated = group.members.map { value.files[$0] }.filter { $0.role != .sidecar && $0.ownDate != nil }.min { $0.role < $1.role }
            let date = dated?.ownDate ?? fallback
            let origin = dated.map { ($0.ownDateOrigin ?? "metadata") + ($0.cachedCaptureMetadata ? " (cached metadata)" : "") } ?? (fallback == nil ? "missing" : "user-selected date")
            value.groups[index].date = date
            value.groups[index].dateOrigin = origin
            value.groups[index].folder = try date.map { try Importer.folder(template: template, event: event, date: $0) }
            for member in group.members {
                var file = value.files[member]
                file.date = date; file.folder = value.groups[index].folder
                if let own = file.ownDate, own == date, let ownOrigin = file.ownDateOrigin { file.dateOrigin = ownOrigin + (file.cachedCaptureMetadata ? " (cached metadata)" : "") }
                else if let source = dated, source.source != file.source {
                    file.dateOrigin = "from \(source.source.lastPathComponent) (\(origin))" + (file.ownDate.map { "; own date \($0.text)" } ?? "")
                } else { file.dateOrigin = origin }
                value.files[member] = file
            }
        }
        return value
    }

    /// Mark files verified by an import as present, without rereading anything.
    /// Display-only: every later import re-confirms duplicates by content.
    func applying(_ outcomes: [String: URL]) -> ImportPlan {
        var value = self
        for index in value.files.indices where outcomes[value.files[index].source.path] != nil {
            value.files[index].existing = outcomes[value.files[index].source.path]; value.files[index].companion = false; value.files[index].besideDirectory = nil; value.files[index].cachedVerification = false
        }
        for index in value.groups.indices { value.groups[index].status = Importer.status(value.members(value.groups[index]), source: source) }
        return value
    }
}

struct ReceiptEntry: Codable {
    let source: String, destination: String, sha256: String, action: String, captureDate: String?, dateOrigin: String
    var group: String? = nil
    var role: String? = nil
}
struct Receipt: Codable {
    let started: Date
    var source: String? = nil
    var destinationRoot: String? = nil
    var selectedGroups: Int? = nil
    var entries: [ReceiptEntry] = []
    var notes: [String] = []
    var complete = false
    var cancelled = false
    var error: String?
}
struct ImportResult {
    let copied: Int, skipped: Int, groups: Int
    let folders: [URL], receipt: URL
    let outcomes: [String: URL]
    let notes: [String]
}

enum Importer {
    static var media: Set<String> { MediaTypes.media }
    static let fm = FileManager.default

    static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."),
              !value.contains("/"), !value.contains("\\"), !value.contains(":"),
              value.utf8.count <= 220, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ImportError("Folder names must be 1–220 bytes and cannot start with a dot or contain /, \\, :, or control characters.")
        }
    }
    static func folder(template: String, event: String, date: CaptureDay) throws -> String {
        if template.contains("{event}") {
            guard !event.isEmpty else { throw ImportError("This folder structure uses {event}. Enter an event name or choose a structure without one.") }
            try validateComponent(event)
        }
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
        // Compare case-insensitively: cards (exFAT/FAT) and default APFS volumes ignore case.
        let a = source.standardizedFileURL.path.lowercased() + "/", b = root.standardizedFileURL.path.lowercased() + "/"
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
        var after = stat(); guard fstat(fd, &after) == 0, stable(before, after), bytes == UInt64(before.st_size) else {
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
    static func digestPair(_ source: URL, _ candidate: URL, cancellation: Cancellation,
                           metrics: ReadMetrics? = nil) throws -> (String, String) {
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
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
            a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }

    // A sample rejects candidates or validates an unchanged-file cache record;
    // it cannot independently establish byte equality.
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
          try autoreleasepool {
            try cancellation.check()
            try handle.seek(toOffset: offset)
            let count = Int(min(chunk, size - offset))
            let data = try handle.read(upToCount: count) ?? Data()
            guard data.count == count else { throw ImportError("File changed while sampling. Scan again.") }
            hash.update(data: data); metrics?.sampledBytes += UInt64(data.count)
          }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, stable(before, after) else { throw ImportError("File changed while sampling. Scan again.") }
        return (hex(hash.finalize()), after)
    }

    /// Complete metadata fallback using the bundled ExifTool.
    static func dates(_ urls: [URL], helper: MetadataHelper, cancellation: Cancellation) throws -> [String: (CaptureDay, String)] {
        try helper.validate()
        var result: [String: (CaptureDay, String)] = [:]
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
            let process = helper.process(arguments: ["-j", "-G1", "-a", "-DateTimeOriginal", "-SubSecDateTimeOriginal", "-CreateDate", "-CreationDate", "--"] + batch.map(\.path))
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
                  let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: outputURL)) as? [[String: Any]] else {
                throw ImportError("The built-in metadata reader could not read this source. No photos have been copied.")
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
        }
        return result
    }

    static func captureDates(_ urls: [URL], helper: MetadataHelper, cancellation: Cancellation, metrics: ReadMetrics? = nil,
                             progress: (Int) -> Void = { _ in }) throws -> [String: (CaptureDay, String)] {
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
               let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String, let day = CaptureDay.parse(text) {
                result[url.path] = (day, "ExifIFD:DateTimeOriginal")
            } else { unresolved.append(url) }
          }
        }
        if !unresolved.isEmpty { result.merge(try dates(unresolved, helper: helper, cancellation: cancellation)) { first, _ in first } }
        return result
    }

    static func status(_ members: [PlannedFile], source: URL) -> GroupStatus {
        let primaries = members.filter { $0.role != .sidecar }
        let newPrimaries = primaries.filter { $0.existing == nil }.count
        if newPrimaries == primaries.count { return .new }
        if newPrimaries > 0 { return .partial }
        if members.contains(where: { $0.role == .sidecar && $0.existing == nil }) { return .sidecarChanged }
        if primaries.contains(where: { $0.existing!.path.hasPrefix(source.path + "/") }) { return .sourceDuplicate }
        return .imported
    }

    /// Where a group's new files go when some of its photos are already imported.
    struct BesidePhoto { let directory: URL; var files: [PlannedFile]; var names: [String]; let sharedSuffix: Bool }
    struct SidecarResolution {
        var present: [(PlannedFile, URL, String)] = []
        var withNewPhotos: [PlannedFile] = []
        var beside: [BesidePhoto] = []
    }

    /// Decides each sidecar's state from the content-confirmed destination copies of its photo(s).
    ///
    /// - A sidecar of a photo being copied now travels with that photo into the date folder.
    /// - Otherwise it is present only when an identical copy sits beside an imported copy of its photo
    ///   under the associated name (`<photo base>.xmp`, or `<photo filename>.dop` for full-filename
    ///   sidecars). Identical sidecar contents elsewhere, such as template XMP files, are not evidence.
    /// - A missing sidecar is placed beside the imported photo under the associated name.
    /// - A changed sidecar (that name holds different contents beside every imported copy) is imported
    ///   with a fresh copy of the photo(s) it belongs to, all with one shared suffix, so the pair stays
    ///   usable in editors and existing files are untouched. A rescan finds the sidecar beside that copy.
    /// No capture date is needed for files placed beside an imported photo.
    static func resolveSidecars(_ sidecars: [PlannedFile], primaries: [PlannedFile], matches: [URL: [URL]], root: URL,
                                cancellation: Cancellation, metrics: ReadMetrics?) throws -> SidecarResolution {
        var result = SidecarResolution()
        var conflicts: [URL: (sidecars: [PlannedFile], photos: [PlannedFile])] = [:]
        for sidecar in sidecars {
            let related = primaries.filter { sidecar.namedPrimary == nil || $0.source == sidecar.namedPrimary }
            let locations = related.flatMap { photo in (matches[photo.source] ?? []).filter { $0.path.hasPrefix(root.path + "/") }.map { (photo, $0) } }
            guard !related.isEmpty, related.allSatisfy({ !(matches[$0.source] ?? []).isEmpty }), !locations.isEmpty else {
                result.withNewPhotos.append(sidecar); continue
            }
            let hash = try sidecar.digest ?? digest(sidecar.source, cancellation: cancellation, metrics: metrics).0
            var present: URL?, free: (URL, String)?
            for (_, location) in locations {
                let directory = location.deletingLastPathComponent()
                let name = Grouping.sidecarName(sidecar.source, primaryNamed: sidecar.namedPrimary != nil, besidePrimaryNamed: location.lastPathComponent)
                try assertDirectory(directory)
                switch try nameState(directory.appendingPathComponent(name), hash: hash, size: sidecar.size, cancellation: cancellation) {
                case .identical: present = directory.appendingPathComponent(name)
                case .free: if free == nil { free = (directory, name) }
                case .different: break
                }
                if present != nil { break }
            }
            var file = sidecar; file.digest = hash
            if let present { result.present.append((file, present, hash)) }
            else if let (directory, name) = free { result.beside.append(BesidePhoto(directory: directory, files: [file], names: [name], sharedSuffix: false)) }
            else {
                let directory = locations[0].1.deletingLastPathComponent()
                conflicts[directory, default: ([], [])].sidecars.append(file)
                for photo in related where !conflicts[directory]!.photos.contains(where: { $0.source == photo.source }) { conflicts[directory]!.photos.append(photo) }
            }
        }
        for (directory, conflict) in conflicts.sorted(by: { $0.key.path < $1.key.path }) {
            let files = conflict.photos + conflict.sidecars
            result.beside.append(BesidePhoto(directory: directory, files: files, names: files.map(\.source.lastPathComponent), sharedSuffix: true))
        }
        return result
    }

    /// Preview an import. Never writes originals; an optional local cache stores hash hints.
    /// `discovered` receives the related-file groups as soon as the source is listed,
    /// before dates and duplicates are known.
    static func plan(source: URL, settings: Settings, event: String, fallback: CaptureDay?, helper: MetadataHelper, cancellation: Cancellation,
                     verificationCache: DuplicateVerificationCache? = nil, reuseCachedHashes: Bool = true,
                     progress: (ImportProgress) -> Void, discovered: (([SourceGroup]) -> Void)? = nil) throws -> ImportPlan {
        let root = URL(fileURLWithPath: settings.destination, isDirectory: true).standardizedFileURL
        try validateLocations(source: source, root: root)
        _ = try folder(template: settings.folderTemplate, event: event, date: CaptureDay(year: 2026, month: 10, day: 4))
        try helper.validate()
        progress(ImportProgress("Listing photos…"))
        let (all, unsupported) = try files(in: source, allowed: MediaTypes.importable, cancellation: cancellation)
        let (sourceGroups, orphans) = Grouping.group(all)
        guard !sourceGroups.isEmpty else { throw ImportError("No supported photos or videos were found in this source.") }
        discovered?(sourceGroups)
        let primaries = sourceGroups.flatMap(\.primaries)
        let members = sourceGroups.flatMap(\.members)
        let metadataVersions = try Dictionary(uniqueKeysWithValues: members.map { ($0, try info($0)) })
        let metrics = ReadMetrics()
        let cacheNamespace = DuplicateVerificationCache.namespace(root: root)
        var metadata: [String: (CaptureDay, String)] = [:]
        var cachedSources: [URL: (sample: String, version: stat, hash: String)] = [:]
        let inspectMetadataCache = reuseCachedHashes && (verificationCache?.count ?? 0) > 0
        if inspectMetadataCache, let cache = verificationCache, let namespace = cacheNamespace {
            for (index, url) in primaries.enumerated() {
              try autoreleasepool {
                try cancellation.check()
                if index % 25 == 0 {
                    progress(ImportProgress("Checking cached capture dates (\(index + 1) of \(primaries.count))…", fraction: 0.2 * Double(index) / Double(primaries.count)))
                }
                guard let initial = metadataVersions[url], cache.hasCaptureMetadata(for: url, namespace: namespace, info: initial) else { return }
                let (sample, version) = try fingerprint(url, cancellation: cancellation, metrics: metrics)
                if let fact = cache.captureMetadata(for: url, namespace: namespace, info: version, sample: sample) {
                    metadata[url.path] = (fact.0, fact.1)
                    cachedSources[url] = (sample, version, fact.2)
                    metrics.cachedCaptureDates += 1
                }
              }
            }
        }
        let needsMetadata = primaries.filter { metadata[$0.path] == nil }
        let dateBase = inspectMetadataCache ? 0.2 : 0.0
        metadata.merge(try captureDates(needsMetadata, helper: helper, cancellation: cancellation, metrics: metrics) { index in
            if index % 25 == 0 { progress(ImportProgress("Reading capture dates (\(index + 1) of \(needsMetadata.count))…", fraction: dateBase + (0.4 - dateBase) * Double(index) / Double(needsMetadata.count))) }
        }) { _, fresh in fresh }
        progress(ImportProgress("Checking the destination for photos already imported…", fraction: 0.4))
        let library = try LibraryIndex(root: root, cancellation: cancellation, verificationCache: verificationCache, reuseCachedHashes: reuseCachedHashes)
        var planned: [PlannedFile] = [], groups: [PhotoGroup] = []
        var seen: [String: [URL]] = [:]
        var checked = 0
        var lastCheckProgress = Date.distantPast
        for (groupID, sourceGroup) in sourceGroups.enumerated() {
            var indices: [Int] = []
            var matches: [URL: [URL]] = [:]
            let sidecarPrimary = Dictionary(sourceGroup.sidecars.map { ($0.url, $0.primary) }, uniquingKeysWith: { a, _ in a })
            for url in sourceGroup.members {
                checked += 1
                let now = Date()
                if checked == 1 || checked == members.count || now.timeIntervalSince(lastCheckProgress) >= 0.1 {
                    lastCheckProgress = now
                    progress(ImportProgress("Checking \(checked) of \(members.count): \(url.lastPathComponent)", fraction: 0.4 + 0.6 * Double(checked) / Double(members.count)))
                }
                let role = MediaTypes.role(of: url)!
                let sample: String, version: stat
                if let cached = cachedSources[url] {
                    guard stable(cached.version, try info(url)) else { throw ImportError("Source changed while reading cached capture dates. Scan again.") }
                    sample = cached.sample; version = cached.version
                } else {
                    let fresh = try fingerprint(url, cancellation: cancellation, metrics: metrics)
                    sample = fresh.0; version = fresh.1
                }
                // Filesystem metadata updates can change ctime during metadata discovery.
                // The preview snapshot below retains ctime for strict import-time checks.
                guard let metadataVersion = metadataVersions[url], metadataVersion.st_dev == version.st_dev,
                      metadataVersion.st_ino == version.st_ino, metadataVersion.st_size == version.st_size,
                      metadataVersion.st_mtimespec.tv_sec == version.st_mtimespec.tv_sec,
                      metadataVersion.st_mtimespec.tv_nsec == version.st_mtimespec.tv_nsec else {
                    throw ImportError("\(url.lastPathComponent) changed while reading capture dates. Scan again.")
                }
                let size = UInt64(version.st_size), key = "\(size):\(sample)"
                var file = PlannedFile(source: url, role: role, group: groupID, namedPrimary: sidecarPrimary[url] ?? nil, size: size,
                                       fingerprint: sample, sourceInfo: version, digest: nil, existing: nil,
                                       ownDate: metadata[url.path]?.0, ownDateOrigin: metadata[url.path]?.1)
                file.cachedCaptureMetadata = cachedSources[url] != nil
                // Bind any reused date to the complete hash that originally established it.
                // This remains required even if the destination copy has disappeared.
                file.digest = cachedSources[url]?.hash
                if role != .sidecar {
                    var hash = file.digest
                    // Every confirmed copy matters when sidecars must be found beside one of them.
                    let found = try library.matches(source: url, size: size, fingerprint: sample, hash: &hash, all: !sourceGroup.sidecars.isEmpty,
                                                    cancellation: cancellation, metrics: metrics, sourceDevice: version.st_dev)
                    matches[url] = found
                    file.existing = found.first
                    if found.isEmpty {
                        for peer in seen[key] ?? [] {
                            if hash == nil { hash = try digest(url, cancellation: cancellation, metrics: metrics).0 }
                            if try digest(peer, cancellation: cancellation, metrics: metrics).0 == hash { file.existing = peer; break }
                        }
                    }
                    file.digest = hash
                    seen[key, default: []].append(url)
                }
                file.cachedVerification = file.existing != nil && (file.cachedCaptureMetadata || library.cachedFiles.contains(url) || matches[url, default: []].contains { library.cachedFiles.contains($0) })
                guard stable(version, try info(url)) else { throw ImportError("Source changed during preview. Scan again.") }
                if let cache = verificationCache, let namespace = cacheNamespace {
                    cache.recordCaptureMetadata(url, namespace: namespace, info: version, sample: sample, day: file.ownDate, origin: file.ownDateOrigin)
                }
                indices.append(planned.count); planned.append(file)
            }
            let primaryIndices = indices.filter { planned[$0].role != .sidecar }, sidecarIndices = indices.filter { planned[$0].role == .sidecar }
            let resolution = try resolveSidecars(sidecarIndices.map { planned[$0] }, primaries: primaryIndices.map { planned[$0] }, matches: matches,
                                                 root: root, cancellation: cancellation, metrics: metrics)
            func index(_ file: PlannedFile) -> Int { indices.first { planned[$0].source == file.source }! }
            for (file, target, hash) in resolution.present { planned[index(file)].existing = target; planned[index(file)].digest = hash }
            for placement in resolution.beside {
                for file in placement.files {
                    planned[index(file)].besideDirectory = placement.directory
                    if file.role != .sidecar { planned[index(file)].companion = true } else { planned[index(file)].digest = file.digest }
                }
            }
            let first = planned[indices[0]]
            groups.append(PhotoGroup(id: groupID, name: first.source.deletingPathExtension().lastPathComponent, directory: first.source.deletingLastPathComponent(),
                                     members: indices, date: nil, dateOrigin: "missing", folder: nil,
                                     status: status(indices.map { planned[$0] }, source: source)))
        }
        let plan = ImportPlan(source: source, root: root, settings: settings, event: event, fallback: fallback, files: planned, groups: groups,
                              ignored: unsupported, orphanSidecars: orphans, scanReads: metrics)
        let organized = try plan.organized(template: settings.folderTemplate, event: event, fallback: fallback)
        try cancellation.check(); verificationCache?.save()
        return organized
    }

    /// A folder beside an imported photo may be the destination root itself or any real
    /// directory inside it; paths outside the root and symlinked components are refused.
    static func validatePlacement(_ directory: URL, root: URL) throws {
        let folder = directory.standardizedFileURL.path, base = root.standardizedFileURL.path
        guard folder == base || folder.hasPrefix(base + "/") else { throw ImportError("A photo's folder is outside the destination. Scan again.") }
        try assertDirectory(directory)
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

    struct StagedFile { let file: PlannedFile; let staging: URL; let hash: String }

    /// Copy into a hidden staging file in the destination folder, flush, read back, and verify.
    /// Nothing is visible under its final name until `publish`.
    static func stage(_ file: PlannedFile, in directory: URL, cancellation: Cancellation, copied: (UInt64) -> Void = { _ in }) throws -> StagedFile {
        try assertDirectory(directory)
        let staging = directory.appendingPathComponent(".photo-import-" + UUID().uuidString + ".partial")
        let outputFD = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard outputFD >= 0 else { throw ImportError("Cannot write to \(directory.path)") }
        var keep = false
        defer { close(outputFD); if !keep { try? fm.removeItem(at: staging) } }
        let output = FileHandle(fileDescriptor: outputFD, closeOnDealloc: false)
        let inputFD = open(file.source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard inputFD >= 0 else { throw ImportError("Cannot read \(file.source.path)") }
        defer { close(inputFD) }
        var before = stat(); guard fstat(inputFD, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw ImportError("Source is not a regular file.") }
        guard stable(file.sourceInfo, before) else { throw ImportError("Source changed since the preview. Scan again.") }
        let input = FileHandle(fileDescriptor: inputFD, closeOnDealloc: false)
        var hash = SHA256(), bytes: UInt64 = 0
        while try autoreleasepool(invoking: { () throws -> Bool in
            try cancellation.check()
            guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { return false }
            try output.write(contentsOf: data); hash.update(data: data); bytes += UInt64(data.count)
            copied(UInt64(data.count))
            return true
        }) {}
        var after = stat()
        let copiedHash = hex(hash.finalize())
        guard fstat(inputFD, &after) == 0, stable(before, after), bytes == file.size, file.digest == nil || copiedHash == file.digest else {
            throw ImportError("\(file.source.lastPathComponent) changed since the preview. Scan again; it was not imported.")
        }
        guard fsync(outputFD) == 0 else { throw ImportError("Could not flush the copied file to disk.") }
        let (readBack, readSize) = try digest(staging, cancellation: cancellation)
        guard readBack == copiedHash, readSize == file.size else { throw ImportError("Copy verification failed for \(file.source.lastPathComponent). The card will not be ejected.") }
        // Preserve file timestamps after verification. The source bytes and embedded metadata are untouched.
        var times = [before.st_atimespec, before.st_mtimespec]
        guard futimens(outputFD, &times) == 0, fchmod(outputFD, 0o644) == 0, fsync(outputFD) == 0 else { throw ImportError("Could not finalize the verified copy.") }
        keep = true
        return StagedFile(file: file, staging: staging, hash: copiedHash)
    }

    enum NameState { case free, identical, different }
    static func nameState(_ target: URL, hash: String, size: UInt64, cancellation: Cancellation) throws -> NameState {
        var value = stat()
        if lstat(target.path, &value) != 0 { return errno == ENOENT ? .free : .different }
        guard value.st_mode & S_IFMT == S_IFREG, UInt64(value.st_size) == size else { return .different }
        return try digest(target, cancellation: cancellation).0 == hash ? .identical : .different
    }

    /// Publish verified staging files under `desired` names (original names by default). If any name
    /// already holds different contents, or `sharedSuffix` is set, every file receives the same suffix
    /// so related files stay associated. Exclusive rename never replaces an existing file.
    /// `results` receives each file as soon as it is visible under its final name, so a failure
    /// partway through a group still reports every published file.
    static func publish(_ staged: [StagedFile], in directory: URL, desired: [String]? = nil, sharedSuffix: Bool = false, reason: String? = nil,
                        notes: inout [String], results: inout [(StagedFile, URL, Bool)]) throws {
        let never = Cancellation()
        var remaining: [(item: StagedFile, name: String)] = []
        for (index, item) in staged.enumerated() {
            let name = desired?[index] ?? item.file.source.lastPathComponent
            if !sharedSuffix, try nameState(directory.appendingPathComponent(name), hash: item.hash, size: item.file.size, cancellation: never) == .identical {
                try? fm.removeItem(at: item.staging)
                results.append((item, directory.appendingPathComponent(name), false))
            } else { remaining.append((item, name)) }
        }
        guard !remaining.isEmpty else { return }
        func names(_ suffix: String?) -> [String] {
            remaining.map { entry in
                suffix.map { Grouping.suffixed(entry.name, suffix: $0, primaryNamedSidecar: entry.item.file.namedPrimary != nil) } ?? entry.name
            }
        }
        let groupHash = remaining.count == 1 ? remaining[0].item.hash
            : hex(SHA256.hash(data: Data(remaining.map(\.item.hash).sorted().joined(separator: "\n").utf8)))
        var chosen: [String]?
        for attempt in (sharedSuffix ? 0 : -1)..<10000 {
            let candidate = names(attempt < 0 ? nil : String(groupHash.prefix(16)) + (attempt == 0 ? "" : "-\(attempt)"))
            var usable = true
            for (entry, name) in zip(remaining, candidate) where try nameState(directory.appendingPathComponent(name), hash: entry.item.hash, size: entry.item.file.size, cancellation: never) != .free {
                usable = false; break
            }
            if usable { chosen = candidate; break }
        }
        guard let finalNames = chosen else { throw ImportError("Too many filename collisions for \(remaining[0].item.file.source.lastPathComponent).") }
        if finalNames != names(nil) {
            notes.append(reason.map { "\($0) Imported as \(finalNames.joined(separator: ", ")) in \(directory.path)." }
                ?? "\(remaining.map { $0.item.file.source.lastPathComponent }.joined(separator: ", ")): a different file already used a name in \(directory.path); imported as \(finalNames.joined(separator: ", ")).")
        } else if zip(remaining.map(\.item.file.source.lastPathComponent), finalNames).contains(where: { $0 != $1 }) {
            notes.append("\(remaining.map { $0.item.file.source.lastPathComponent }.joined(separator: ", ")): placed beside the imported photo as \(finalNames.joined(separator: ", ")) in \(directory.path).")
        }
        let remainingItems = remaining.map(\.item)
        for (item, name) in zip(remainingItems, finalNames) {
            try assertDirectory(directory)
            var target = directory.appendingPathComponent(name), isNew = true, attempt = 0
            // macOS exclusive rename publishes without overwriting, even when a filename races.
            while renamex_np(item.staging.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else { throw ImportError("Cannot publish the verified copy: \(String(cString: strerror(errno))). This destination must support macOS exclusive rename; no unsafe overwrite fallback is used.") }
                if try nameState(target, hash: item.hash, size: item.file.size, cancellation: never) == .identical {
                    try? fm.removeItem(at: item.staging); isNew = false; break
                }
                attempt += 1
                guard attempt < 10000 else { throw ImportError("Too many filename collisions for \(item.file.source.lastPathComponent).") }
                target = directory.appendingPathComponent(Grouping.suffixed(item.file.source.lastPathComponent, suffix: String(item.hash.prefix(16)) + "-r\(attempt)", primaryNamedSidecar: item.file.namedPrimary != nil))
            }
            if target.lastPathComponent != name {
                notes.append("\(item.file.source.lastPathComponent): another app created \(name) during the import; imported as \(target.lastPathComponent), which no longer matches its related files' names.")
            }
            results.append((item, target, isNew))
        }
        let directoryFD = open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw ImportError("Cannot flush the destination folder.") }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw ImportError("The copy is verified, but the folder could not be flushed. Keep the card inserted.") }
    }

    /// Previously imported files outside the selection use the same fixed-expiry,
    /// unchanged-file assumption as preview. Uncertain records require full reads.
    private static func verifyCachedPreview(_ plan: ImportPlan, selected: Set<Int>, cancellation: Cancellation,
                                            verificationCache: DuplicateVerificationCache?, metrics: ReadMetrics?,
                                            progress: (ImportProgress) -> Void) throws -> Int {
        // Selected members are rechecked by the normal import path below. Only the
        // cached matches omitted from that selection need this separate preflight.
        let cached = plan.files.filter { $0.cachedVerification && !selected.contains($0.group) }
        let namespace = DuplicateVerificationCache.namespace(root: plan.root)
        var reused = 0
        for (index, file) in cached.enumerated() {
          try autoreleasepool {
            try cancellation.check()
            progress(ImportProgress("Checking previous imports \(index + 1) of \(cached.count): \(file.source.lastPathComponent)", fraction: 0))
            guard let target = file.existing, let expected = file.digest,
                  stable(file.sourceInfo, try info(file.source)) else {
                throw ImportError("A cached match changed. Use Full Verification before importing. The card has not been ejected.")
            }
            try assertDirectory(file.source.deletingLastPathComponent())
            try assertDirectory(target.deletingLastPathComponent())
            let targetInfo = try info(target)
            let sourceSample = try fingerprint(file.source, cancellation: cancellation, metrics: metrics)
            let targetSample = try fingerprint(target, cancellation: cancellation, metrics: metrics)
            guard stable(file.sourceInfo, sourceSample.1), stable(targetInfo, targetSample.1),
                  stable(sourceSample.1, try info(file.source)), stable(targetSample.1, try info(target)) else {
                throw ImportError("A cached match changed while checking it. Scan again before importing.")
            }
            // Look up both sides so a single stale record costs one complete read, not two.
            let sourceHit = namespace.flatMap { verificationCache?.hash(for: file.source, namespace: $0, info: sourceSample.1, sample: sourceSample.0) } == expected
            let targetHit = namespace.flatMap { verificationCache?.hash(for: target, namespace: $0, info: targetSample.1, sample: targetSample.0) } == expected
            if sourceHit && targetHit {
                reused += 1
                return
            }
            progress(ImportProgress("Verifying changed or expired match \(index + 1) of \(cached.count): \(file.source.lastPathComponent)", fraction: 0))
            let hashes: (String, String)
            if sourceHit {
                hashes = (expected, try digest(target, cancellation: cancellation, metrics: metrics).0)
            } else if targetHit {
                hashes = (try digest(file.source, cancellation: cancellation, metrics: metrics).0, expected)
            } else if file.sourceInfo.st_dev != targetInfo.st_dev {
                hashes = try digestPair(file.source, target, cancellation: cancellation, metrics: metrics)
            } else {
                hashes = (try digest(file.source, cancellation: cancellation, metrics: metrics).0,
                          try digest(target, cancellation: cancellation, metrics: metrics).0)
            }
            guard hashes.0 == expected, hashes.1 == expected,
                  stable(file.sourceInfo, try info(file.source)), stable(targetInfo, try info(target)) else {
                throw ImportError("A cached match no longer has identical contents. Use Full Verification before importing. The card has not been ejected.")
            }
            // Refresh only sides that were read in full; a cache hit never renews its TTL.
            if let cache = verificationCache, let namespace {
                if !sourceHit { cache.record(file.source, namespace: namespace, info: sourceSample.1, sample: sourceSample.0, hash: expected) }
                if !targetHit { cache.record(target, namespace: namespace, info: targetSample.1, sample: targetSample.0, hash: expected) }
            }
          }
        }
        return reused
    }

    /// Cached date fields are untrusted preview hints. Re-read selected originals'
    /// native metadata before any publication so even a corrupted cache cannot
    /// silently choose the wrong date folder or falsify report provenance.
    private static func confirmCachedCaptureDates(_ plan: inout ImportPlan, selected: Set<Int>, helper: MetadataHelper?,
                                                  cancellation: Cancellation, progress: (ImportProgress) -> Void) throws {
        let indices = plan.files.indices.filter { selected.contains(plan.files[$0].group) && plan.files[$0].cachedCaptureMetadata }
        guard !indices.isEmpty else { return }
        guard let helper else { throw ImportError("Cached capture dates need the built-in metadata reader. Run Full Verification before importing.") }
        let files = indices.map { plan.files[$0] }
        for file in files {
            try assertDirectory(file.source.deletingLastPathComponent())
            guard stable(file.sourceInfo, try info(file.source)) else { throw ImportError("Source changed since the preview. Scan again.") }
        }
        let fresh = try captureDates(files.map(\.source), helper: helper, cancellation: cancellation) { index in
            if index % 25 == 0 { progress(ImportProgress("Confirming cached capture dates (\(index + 1) of \(files.count))…", fraction: 0)) }
        }
        for index in indices {
            let file = plan.files[index]
            guard let actual = fresh[file.source.path], actual.0 == file.ownDate else {
                throw ImportError("A cached capture date does not match this original. Run Full Verification before importing.")
            }
            plan.files[index].ownDateOrigin = actual.1
            plan.files[index].cachedCaptureMetadata = false
        }
        plan = try plan.organized(template: plan.settings.folderTemplate, event: plan.event, fallback: plan.fallback)
    }

    /// Import the selected groups (all groups when `selection` is nil). Existing members are
    /// re-confirmed by content; new members are staged, verified, published, and verified again
    /// at the end. On cancellation or failure, completed groups stay and `ImportFailure` lists them.
    static func run(_ preview: ImportPlan, selection: Set<Int>? = nil, cancellation: Cancellation, reportDirectory: URL? = nil,
                    verificationCache: DuplicateVerificationCache? = nil, metadataHelper: MetadataHelper? = nil,
                    cachedMatchMetrics: ReadMetrics? = nil,
                    progress: (ImportProgress) -> Void) throws -> ImportResult {
        var plan = preview
        try validateLocations(source: plan.source, root: plan.root)
        let chosen = plan.groups.filter { selection?.contains($0.id) ?? true }
        guard !chosen.isEmpty else { throw ImportError("Select at least one photo to import.") }
        guard plan.missingDates(in: Set(chosen.map(\.id))) == 0 else { throw ImportError("Choose a fallback date for files without capture metadata, then scan again.") }
        let lockURL = plan.root.appendingPathComponent(".photo-import.lock")
        let lockFD = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard lockFD >= 0 else { throw ImportError("Cannot lock this destination.") }
        defer { close(lockFD) }
        var lockInfo = stat()
        guard fstat(lockFD, &lockInfo) == 0, lockInfo.st_mode & S_IFMT == S_IFREG, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            throw ImportError("Another import is using this destination. Wait for it to finish.")
        }
        defer { flock(lockFD, LOCK_UN) }
        let logs = reportDirectory ?? Settings.reportsDirectory
        try fm.createDirectory(at: logs, withIntermediateDirectories: true)
        let receiptURL = logs.appendingPathComponent(UUID().uuidString + ".json")
        var receipt = Receipt(started: Date(), source: plan.sourceDescription ?? plan.source.path, destinationRoot: plan.root.path, selectedGroups: chosen.count)
        func saveReceipt() throws {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(receipt).write(to: receiptURL, options: .atomic)
        }
        try saveReceipt()
        var copied = 0, skipped = 0, folders = Set<URL>(), outcomes: [String: URL] = [:]
        let totalBytes = max(1, plan.bytes(in: Set(chosen.map(\.id))))
        var copiedBytes: UInt64 = 0
        do {
            try confirmCachedCaptureDates(&plan, selected: Set(chosen.map(\.id)), helper: metadataHelper, cancellation: cancellation, progress: progress)
            let cachedMatches = try verifyCachedPreview(plan, selected: Set(chosen.map(\.id)), cancellation: cancellation,
                                                       verificationCache: verificationCache, metrics: cachedMatchMetrics, progress: progress)
            if cachedMatches > 0 {
                receipt.notes.append("\(cachedMatches) previously imported files outside the selection used unexpired cached verification after fresh attribute and content-sample checks. Their full contents were not reread. Full Verification checks complete contents.")
            }
            progress(ImportProgress("Rechecking the destination before copying…", fraction: 0))
            let library = try LibraryIndex(root: plan.root, cancellation: cancellation)
            for (index, group) in chosen.enumerated() {
                try cancellation.check(); try assertDirectory(plan.root)
                progress(ImportProgress("Importing \(index + 1) of \(chosen.count): \(group.name)", fraction: 0.9 * Double(copiedBytes) / Double(totalBytes)))
                var verified: [(PlannedFile, URL, String)] = [], toCopy: [PlannedFile] = [], matches: [URL: [URL]] = [:]
                let members = plan.members(group)
                for file in members {
                    guard stable(file.sourceInfo, try info(file.source)) else { throw ImportError("\(file.source.lastPathComponent) changed since the preview. Scan again.") }
                }
                let sidecars = members.filter { $0.role == .sidecar }
                for file in members where file.role != .sidecar {
                    // Rehash candidates at import time; preview samples are never proof for a skip.
                    var hash: String?
                    let found = try library.matches(source: file.source, size: file.size, fingerprint: file.fingerprint, hash: &hash, all: !sidecars.isEmpty, cancellation: cancellation, sourceDevice: file.sourceInfo.st_dev)
                    matches[file.source] = found
                    if let match = found.first {
                        guard let confirmed = hash, file.digest == nil || confirmed == file.digest,
                              stable(file.sourceInfo, try info(file.source)) else { throw ImportError("Source changed since the preview. Scan again.") }
                        verified.append((file, match, confirmed))
                    } else { toCopy.append(file) }
                }
                let resolution = try resolveSidecars(sidecars, primaries: members.filter { $0.role != .sidecar }, matches: matches, root: plan.root,
                                                     cancellation: cancellation, metrics: nil)
                verified += resolution.present
                toCopy += resolution.withNewPhotos
                var published: [(StagedFile, URL, Bool)] = []
                func record() {
                    for (file, target, hash) in verified {
                        skipped += 1; outcomes[file.source.path] = target
                        receipt.entries.append(ReceiptEntry(source: plan.describedSource(file.source), destination: target.path, sha256: hash, action: "already imported and verified",
                                                            captureDate: file.date?.text, dateOrigin: file.dateOrigin, group: group.name, role: file.role.rawValue))
                    }
                    for (item, target, isNew) in published {
                        if isNew { copied += 1; folders.insert(target.deletingLastPathComponent()) } else { skipped += 1 }
                        outcomes[item.file.source.path] = target
                        receipt.entries.append(ReceiptEntry(source: plan.describedSource(item.file.source), destination: target.path, sha256: item.hash,
                                                            action: isNew ? "copied and verified" : "already imported and verified",
                                                            captureDate: item.file.date?.text, dateOrigin: item.file.dateOrigin, group: group.name, role: item.file.role.rawValue))
                    }
                    verified = []; published = []
                }
                /// Stage every file for one folder, then publish them together.
                func copy(_ files: [PlannedFile], into directory: URL, names: [String]?, sharedSuffix: Bool, reason: String?) throws {
                    var staged: [StagedFile] = []
                    // Remove staging files of an unfinished group; completed groups are kept.
                    defer { for item in staged where fm.fileExists(atPath: item.staging.path) { try? fm.removeItem(at: item.staging) } }
                    for file in files {
                        staged.append(try stage(file, in: directory, cancellation: cancellation) { bytes in
                            copiedBytes += bytes
                            if copiedBytes % (32 * 1024 * 1024) < bytes {
                                progress(ImportProgress("Importing \(index + 1) of \(chosen.count): \(group.name)", fraction: 0.9 * Double(copiedBytes) / Double(totalBytes)))
                            }
                        })
                    }
                    // Publishing a verified group is not interrupted by cancellation.
                    let before = published.count
                    try publish(staged, in: directory, desired: names, sharedSuffix: sharedSuffix, reason: reason, notes: &receipt.notes, results: &published)
                    for (item, target, isNew) in published[before...] where isNew { library.add(target, hash: item.hash, size: item.file.size, fingerprint: item.file.fingerprint) }
                }
                do {
                    if !toCopy.isEmpty {
                        guard let folder = group.folder else { throw ImportError("\(group.name) has no capture date. Choose a fallback date and scan again.") }
                        try copy(toCopy, into: try makeFolder(root: plan.root, relative: folder), names: nil, sharedSuffix: false, reason: nil)
                    }
                    for placement in resolution.beside {
                        try validatePlacement(placement.directory, root: plan.root)
                        let changed = placement.files.filter { $0.role == .sidecar }.map(\.source.lastPathComponent).joined(separator: ", ")
                        let photos = placement.files.filter { $0.role != .sidecar }.map(\.source.lastPathComponent).joined(separator: ", ")
                        progress(ImportProgress("Placing \(placement.files.map(\.source.lastPathComponent).joined(separator: ", ")) beside the imported photo",
                                                fraction: 0.9 * Double(copiedBytes) / Double(totalBytes)))
                        try copy(placement.files, into: placement.directory, names: placement.names, sharedSuffix: placement.sharedSuffix,
                                 reason: placement.sharedSuffix ? "\(changed) differs from the sidecar beside the imported photo, which was kept. The card's version was imported with a matching copy of \(photos)." : nil)
                    }
                } catch {
                    // Any later step of this group failed or was cancelled: everything already
                    // published and verified (and every confirmed existing file) is still reported.
                    record(); throw error
                }
                record()
                try saveReceipt()
            }
            try cancellation.check()
            // Cache is write-only here: every duplicate and final copy is fully re-read.
            let cacheNamespace = DuplicateVerificationCache.namespace(root: plan.root)
            let sourceFiles = Dictionary(uniqueKeysWithValues: chosen.flatMap { plan.members($0) }.map { (plan.describedSource($0.source), $0) })
            // Re-read every final destination before allowing optional ejection.
            for (index, entry) in receipt.entries.enumerated() {
                progress(ImportProgress("Final verification: \(URL(fileURLWithPath: entry.destination).lastPathComponent)", fraction: 0.9 + 0.1 * Double(index) / Double(receipt.entries.count)))
                try assertDirectory(URL(fileURLWithPath: entry.destination).deletingLastPathComponent())
                let target = URL(fileURLWithPath: entry.destination), before = try info(target)
                let (hash, _) = try digest(target, cancellation: cancellation)
                guard hash == entry.sha256 else { throw ImportError("Final verification failed for \(target.lastPathComponent). Keep the card inserted and scan again.") }
                if let cache = verificationCache, let namespace = cacheNamespace, let file = sourceFiles[entry.source], file.role != .sidecar,
                   stable(before, try info(target)), stable(file.sourceInfo, try info(file.source)) {
                    cache.record(file.source, namespace: namespace, info: file.sourceInfo, sample: file.fingerprint, hash: hash)
                    cache.record(target, namespace: namespace, info: before, sample: file.fingerprint, hash: hash)
                    cache.recordCaptureMetadata(file.source, namespace: namespace, info: file.sourceInfo, sample: file.fingerprint, day: file.ownDate, origin: file.ownDateOrigin)
                    cache.recordCaptureMetadata(target, namespace: namespace, info: before, sample: file.fingerprint, day: file.ownDate, origin: file.ownDateOrigin)
                }
            }
            receipt.complete = true; try saveReceipt()
            verificationCache?.save()
        } catch {
            receipt.cancelled = cancellation.isCancelled
            receipt.error = error.localizedDescription; try? saveReceipt()
            let summary = "\(copied) verified \(copied == 1 ? "copy was" : "copies were") completed and kept. The card has not been ejected; scan again to continue. Report: \(receiptURL.path)"
            throw ImportFailure(message: "\(error.localizedDescription)\n\n\(summary)", copied: copied, skipped: skipped,
                                outcomes: outcomes,
                                receipt: receiptURL, cancelled: cancellation.isCancelled)
        }
        return ImportResult(copied: copied, skipped: skipped, groups: chosen.count, folders: folders.sorted { $0.path < $1.path },
                            receipt: receiptURL, outcomes: outcomes, notes: receipt.notes)
    }
}

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
    func match(source: URL, size: UInt64, fingerprint: String, hash: inout String?, cancellation: Cancellation, metrics: ReadMetrics? = nil) throws -> URL? {
        try matches(source: source, size: size, fingerprint: fingerprint, hash: &hash, all: false, cancellation: cancellation, metrics: metrics).first
    }
    private func storedHash(_ url: URL, info: stat, sample: String) -> String? {
        guard reuseCachedHashes, let cache = verificationCache, let namespace = cacheNamespace,
              let hash = cache.hash(for: url, namespace: namespace, info: info, sample: sample) else { return nil }
        cachedFiles.insert(url); return hash
    }
    private func rememberHash(_ url: URL, info: stat, sample: String, hash: String) {
        guard let cache = verificationCache, let namespace = cacheNamespace,
              let after = try? Importer.info(url), Importer.stable(info, after) else { return }
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
            if let cached = samples[url], Importer.stable(cached.0, current) { sample = cached.1 }
            else {
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
                if let cached { candidate = cached }
                else {
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
