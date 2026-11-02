import Darwin
import Foundation

extension Importer {
    /// Previously imported files outside the selection use the same fixed-expiry,
    /// unchanged-file assumption as preview. Uncertain records require full reads.
    private static func verifyCachedPreview(
        _ plan: ImportPlan, selected: Set<Int>, cancellation: Cancellation,
        verificationCache: DuplicateVerificationCache?, metrics: ReadMetrics?,
        progress: (ImportProgress) -> Void
    ) throws -> Int {
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
                    stable(file.sourceInfo, try info(file.source))
                else {
                    throw ImportError("A cached match changed. Use Full Verification before importing. The card has not been ejected.")
                }
                try assertDirectory(file.source.deletingLastPathComponent())
                try assertDirectory(target.deletingLastPathComponent())
                let targetInfo = try info(target)
                let sourceSample = try fingerprint(file.source, cancellation: cancellation, metrics: metrics)
                let targetSample = try fingerprint(target, cancellation: cancellation, metrics: metrics)
                guard stable(file.sourceInfo, sourceSample.1), stable(targetInfo, targetSample.1),
                    stable(sourceSample.1, try info(file.source)), stable(targetSample.1, try info(target))
                else {
                    throw ImportError("A cached match changed while checking it. Scan again before importing.")
                }
                // Look up both sides so a single stale record costs one complete read, not two.
                let sourceHit =
                    (file.transferVerified && sourceSample.0 == file.fingerprint)
                    || namespace.flatMap { verificationCache?.hash(for: file.source, namespace: $0, info: sourceSample.1, sample: sourceSample.0) } == expected
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
                    hashes = (
                        try digest(file.source, cancellation: cancellation, metrics: metrics).0,
                        try digest(target, cancellation: cancellation, metrics: metrics).0
                    )
                }
                guard hashes.0 == expected, hashes.1 == expected,
                    stable(file.sourceInfo, try info(file.source)), stable(targetInfo, try info(target))
                else {
                    throw ImportError("A cached match no longer has identical contents. Use Full Verification before importing. The card has not been ejected.")
                }
                // Refresh only sides that were read in full; a cache hit never renews its TTL.
                if let cache = verificationCache, let namespace {
                    if !sourceHit && !file.transferVerified { cache.record(file.source, namespace: namespace, info: sourceSample.1, sample: sourceSample.0, hash: expected) }
                    if !targetHit { cache.record(target, namespace: namespace, info: targetSample.1, sample: targetSample.0, hash: expected) }
                }
            }
        }
        return reused
    }

    /// Omitted other-card copies (ADR-0014) were recognized without byte proof. Before import,
    /// confirm each recognized destination file is still there with the same size and samples.
    private static func verifyOtherCardCopies(
        _ plan: ImportPlan, selected: Set<Int>, cancellation: Cancellation,
        progress: (ImportProgress) -> Void
    ) throws -> Int {
        let omitted = plan.files.filter { $0.otherCardCopy && !selected.contains($0.group) }
        for (index, file) in omitted.enumerated() {
            try autoreleasepool {
                try cancellation.check()
                if index % 25 == 0 { progress(ImportProgress("Checking photos imported from the other card \(index + 1) of \(omitted.count)…", fraction: 0)) }
                guard let target = file.existing, stable(file.sourceInfo, try info(file.source)) else { throw ImportError("Source changed since the preview. Scan again.") }
                try assertDirectory(target.deletingLastPathComponent())
                guard let (parts, value) = try? sampleParts(target, cancellation: cancellation), UInt64(value.st_size) == file.size,
                    Array(parts.dropFirst()) == file.otherCardSamples
                else {
                    throw ImportError("A photo recognized from the camera's other card is missing or changed in the destination. Scan again before importing. The card has not been ejected.")
                }
            }
        }
        return omitted.count
    }

    /// Cached date fields are untrusted preview hints. Re-read selected originals'
    /// native metadata before any publication so even a corrupted cache cannot
    /// silently choose the wrong date folder or falsify report provenance.
    private static func confirmCachedCaptureDates(
        _ plan: inout ImportPlan, selected: Set<Int>, helper: MetadataHelper?,
        cancellation: Cancellation, progress: (ImportProgress) -> Void
    ) throws {
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
    static func run(
        _ preview: ImportPlan, selection: Set<Int>? = nil, cancellation: Cancellation, reportDirectory: URL? = nil,
        verificationCache: DuplicateVerificationCache? = nil, metadataHelper: MetadataHelper? = nil,
        cachedMatchMetrics: ReadMetrics? = nil,
        progress: (ImportProgress) -> Void
    ) throws -> ImportResult {
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
            let cachedMatches = try verifyCachedPreview(
                plan, selected: Set(chosen.map(\.id)), cancellation: cancellation,
                verificationCache: verificationCache, metrics: cachedMatchMetrics, progress: progress)
            let otherCard = try verifyOtherCardCopies(plan, selected: Set(chosen.map(\.id)), cancellation: cancellation, progress: progress)
            if otherCard > 0 {
                receipt.notes.append(
                    "\(otherCard) photos outside the selection were treated as already imported from the camera's other card. Each matches an imported file's camera serial number, capture time, metadata, size, and content samples, but differs in card-slot metadata, so it is not byte-identical."
                )
            }
            if cachedMatches > 0 {
                receipt.notes.append(
                    "\(cachedMatches) previously imported files outside the selection used unexpired cached verification after fresh attribute and content-sample checks. Their full contents were not reread. Full Verification checks complete contents."
                )
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
                    let found = try library.matches(
                        source: file.source, size: file.size, fingerprint: file.fingerprint, hash: &hash, all: !sidecars.isEmpty, cancellation: cancellation, sourceDevice: file.sourceInfo.st_dev)
                    matches[file.source] = found
                    if let match = found.first {
                        guard let confirmed = hash, file.digest == nil || confirmed == file.digest,
                            stable(file.sourceInfo, try info(file.source))
                        else { throw ImportError("Source changed since the preview. Scan again.") }
                        verified.append((file, match, confirmed))
                    } else {
                        toCopy.append(file)
                    }
                }
                let resolution = try resolveSidecars(
                    sidecars, primaries: members.filter { $0.role != .sidecar }, matches: matches, root: plan.root,
                    cancellation: cancellation, metrics: nil)
                verified += resolution.present
                toCopy += resolution.withNewPhotos
                var published: [(StagedFile, URL, Bool)] = []
                func record() {
                    for (file, target, hash) in verified {
                        skipped += 1; outcomes[file.source.path] = target
                        receipt.entries.append(
                            ReceiptEntry(
                                source: plan.describedSource(file.source), destination: target.path, sha256: hash, action: "already imported and verified",
                                captureDate: file.date?.text, dateOrigin: file.dateOrigin, group: group.name, role: file.role.rawValue))
                    }
                    for (item, target, isNew) in published {
                        if isNew { copied += 1; folders.insert(target.deletingLastPathComponent()) } else { skipped += 1 }
                        outcomes[item.file.source.path] = target
                        receipt.entries.append(
                            ReceiptEntry(
                                source: plan.describedSource(item.file.source), destination: target.path, sha256: item.hash,
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
                        staged.append(
                            try stage(file, in: directory, cancellation: cancellation) { bytes in
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
                        progress(
                            ImportProgress(
                                "Placing \(placement.files.map(\.source.lastPathComponent).joined(separator: ", ")) beside the imported photo",
                                fraction: 0.9 * Double(copiedBytes) / Double(totalBytes)))
                        try copy(
                            placement.files, into: placement.directory, names: placement.names, sharedSuffix: placement.sharedSuffix,
                            reason: placement.sharedSuffix
                                ? "\(changed) differs from the sidecar beside the imported photo, which was kept. The card's version was imported with a matching copy of \(photos)." : nil)
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
                    stable(before, try info(target)), stable(file.sourceInfo, try info(file.source))
                {
                    if !file.transferVerified {
                        cache.record(file.source, namespace: namespace, info: file.sourceInfo, sample: file.fingerprint, hash: hash)
                        cache.recordCaptureMetadata(file.source, namespace: namespace, info: file.sourceInfo, sample: file.fingerprint, day: file.ownDate, origin: file.ownDateOrigin)
                    }
                    cache.record(target, namespace: namespace, info: before, sample: file.fingerprint, hash: hash)
                    cache.recordCaptureMetadata(target, namespace: namespace, info: before, sample: file.fingerprint, day: file.ownDate, origin: file.ownDateOrigin)
                }
            }
            receipt.complete = true; try saveReceipt()
            verificationCache?.save()
        } catch {
            receipt.cancelled = cancellation.isCancelled
            receipt.error = error.localizedDescription; try? saveReceipt()
            let summary = "\(copied) verified \(copied == 1 ? "copy was" : "copies were") completed and kept. The card has not been ejected; scan again to continue. Report: \(receiptURL.path)"
            throw ImportFailure(
                message: "\(error.localizedDescription)\n\n\(summary)", copied: copied, skipped: skipped,
                outcomes: outcomes,
                receipt: receiptURL, cancelled: cancellation.isCancelled)
        }
        return ImportResult(
            copied: copied, skipped: skipped, groups: chosen.count, folders: folders.sorted { $0.path < $1.path },
            receipt: receiptURL, outcomes: outcomes, notes: receipt.notes)
    }
}
