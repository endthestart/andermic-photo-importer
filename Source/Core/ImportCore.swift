import Darwin
import Foundation

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
    /// `digest` is the complete hash taken while transferring this camera copy. Disposable
    /// copies are never written to the persistent cache.
    var transferVerified = false
    /// ADR-0014: treated as imported because it differs from `existing` only in card-slot
    /// metadata. Recognition, not byte proof; `otherCardSamples` are its middle and last samples.
    var otherCardCopy = false
    var otherCardSamples: [String] = []
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
    var otherCardGroups: Int { groups.filter { members($0).contains(where: \.otherCardCopy) }.count }

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
                if let own = file.ownDate, own == date, let ownOrigin = file.ownDateOrigin {
                    file.dateOrigin = ownOrigin + (file.cachedCaptureMetadata ? " (cached metadata)" : "")
                } else if let source = dated, source.source != file.source {
                    file.dateOrigin = "from \(source.source.lastPathComponent) (\(origin))" + (file.ownDate.map { "; own date \($0.text)" } ?? "")
                } else {
                    file.dateOrigin = origin
                }
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
            value.files[index].existing = outcomes[value.files[index].source.path]; value.files[index].companion = false; value.files[index].besideDirectory = nil;
            value.files[index].cachedVerification = false
            value.files[index].otherCardCopy = false
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
            value.utf8.count <= 220, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ImportError("Folder names must be 1–220 bytes and cannot start with a dot or contain /, \\, :, or control characters.")
        }
    }
    static func folder(template: String, event: String, date: CaptureDay) throws -> String {
        if template.contains("{event}") {
            guard !event.isEmpty else { throw ImportError("This folder structure uses {event}. Enter an event name or choose a structure without one.") }
            try validateComponent(event)
        }
        var path = template
        let tokens = [
            "{YYYY}": String(format: "%04d", date.year), "{YY}": String(format: "%02d", date.year % 100),
            "{MM}": String(format: "%02d", date.month), "{DD}": String(format: "%02d", date.day), "{event}": event,
        ]
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
        guard
            let walker = fm.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, error in
                    enumerationError = error; return false
                })
        else {
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
}
