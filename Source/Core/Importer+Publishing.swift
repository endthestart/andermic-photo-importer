import CryptoKit
import Darwin
import Foundation

extension Importer {
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
    static func publish(
        _ staged: [StagedFile], in directory: URL, desired: [String]? = nil, sharedSuffix: Bool = false, reason: String? = nil,
        notes: inout [String], results: inout [(StagedFile, URL, Bool)]
    ) throws {
        let never = Cancellation()
        var remaining: [(item: StagedFile, name: String)] = []
        for (index, item) in staged.enumerated() {
            let name = desired?[index] ?? item.file.source.lastPathComponent
            if !sharedSuffix, try nameState(directory.appendingPathComponent(name), hash: item.hash, size: item.file.size, cancellation: never) == .identical {
                try? fm.removeItem(at: item.staging)
                results.append((item, directory.appendingPathComponent(name), false))
            } else {
                remaining.append((item, name))
            }
        }
        guard !remaining.isEmpty else { return }
        func names(_ suffix: String?) -> [String] {
            remaining.map { entry in
                suffix.map { Grouping.suffixed(entry.name, suffix: $0, primaryNamedSidecar: entry.item.file.namedPrimary != nil) } ?? entry.name
            }
        }
        let groupHash =
            remaining.count == 1
            ? remaining[0].item.hash
            : hex(SHA256.hash(data: Data(remaining.map(\.item.hash).sorted().joined(separator: "\n").utf8)))
        var chosen: [String]?
        for attempt in (sharedSuffix ? 0 : -1)..<10000 {
            let candidate = names(attempt < 0 ? nil : String(groupHash.prefix(16)) + (attempt == 0 ? "" : "-\(attempt)"))
            var usable = true
            for (entry, name) in zip(remaining, candidate) where try nameState(directory.appendingPathComponent(name), hash: entry.item.hash, size: entry.item.file.size, cancellation: never) != .free
            {
                usable = false; break
            }
            if usable { chosen = candidate; break }
        }
        guard let finalNames = chosen else { throw ImportError("Too many filename collisions for \(remaining[0].item.file.source.lastPathComponent).") }
        if finalNames != names(nil) {
            notes.append(
                reason.map { "\($0) Imported as \(finalNames.joined(separator: ", ")) in \(directory.path)." }
                    ?? "\(remaining.map { $0.item.file.source.lastPathComponent }.joined(separator: ", ")): a different file already used a name in \(directory.path); imported as \(finalNames.joined(separator: ", "))."
            )
        } else if zip(remaining.map(\.item.file.source.lastPathComponent), finalNames).contains(where: { $0 != $1 }) {
            notes.append(
                "\(remaining.map { $0.item.file.source.lastPathComponent }.joined(separator: ", ")): placed beside the imported photo as \(finalNames.joined(separator: ", ")) in \(directory.path).")
        }
        let remainingItems = remaining.map(\.item)
        for (item, name) in zip(remainingItems, finalNames) {
            try assertDirectory(directory)
            var target = directory.appendingPathComponent(name), isNew = true, attempt = 0
            // macOS exclusive rename publishes without overwriting, even when a filename races.
            while renamex_np(item.staging.path, target.path, UInt32(RENAME_EXCL)) != 0 {
                guard errno == EEXIST else {
                    throw ImportError(
                        "Cannot publish the verified copy: \(String(cString: strerror(errno))). This destination must support macOS exclusive rename; no unsafe overwrite fallback is used.")
                }
                if try nameState(target, hash: item.hash, size: item.file.size, cancellation: never) == .identical {
                    try? fm.removeItem(at: item.staging); isNew = false; break
                }
                attempt += 1
                guard attempt < 10000 else { throw ImportError("Too many filename collisions for \(item.file.source.lastPathComponent).") }
                target = directory.appendingPathComponent(
                    Grouping.suffixed(item.file.source.lastPathComponent, suffix: String(item.hash.prefix(16)) + "-r\(attempt)", primaryNamedSidecar: item.file.namedPrimary != nil))
            }
            if target.lastPathComponent != name {
                notes.append(
                    "\(item.file.source.lastPathComponent): another app created \(name) during the import; imported as \(target.lastPathComponent), which no longer matches its related files' names.")
            }
            results.append((item, target, isNew))
        }
        let directoryFD = open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw ImportError("Cannot flush the destination folder.") }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw ImportError("The copy is verified, but the folder could not be flushed. Keep the card inserted.") }
    }
}
