import Darwin
import Foundation

extension Importer {
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
    static func resolveSidecars(
        _ sidecars: [PlannedFile], primaries: [PlannedFile], matches: [URL: [URL]], root: URL,
        cancellation: Cancellation, metrics: ReadMetrics?
    ) throws -> SidecarResolution {
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
            if let present {
                result.present.append((file, present, hash))
            } else if let (directory, name) = free {
                result.beside.append(BesidePhoto(directory: directory, files: [file], names: [name], sharedSuffix: false))
            } else {
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
    static func plan(
        source: URL, settings: Settings, event: String, fallback: CaptureDay?, helper: MetadataHelper, cancellation: Cancellation,
        verificationCache: DuplicateVerificationCache? = nil, reuseCachedHashes: Bool = true,
        transferred: [String: (version: stat, hash: String)] = [:],
        progress: (ImportProgress) -> Void, discovered: (([SourceGroup]) -> Void)? = nil
    ) throws -> ImportPlan {
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
        metadata.merge(
            try captureDates(needsMetadata, helper: helper, cancellation: cancellation, metrics: metrics) { index in
                if index % 25 == 0 {
                    progress(ImportProgress("Reading capture dates (\(index + 1) of \(needsMetadata.count))…", fraction: dateBase + (0.4 - dateBase) * Double(index) / Double(needsMetadata.count)))
                }
            }
        ) { _, fresh in fresh }
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
                    metadataVersion.st_mtimespec.tv_nsec == version.st_mtimespec.tv_nsec
                else {
                    throw ImportError("\(url.lastPathComponent) changed while reading capture dates. Scan again.")
                }
                let size = UInt64(version.st_size), key = "\(size):\(sample)"
                var file = PlannedFile(
                    source: url, role: role, group: groupID, namedPrimary: sidecarPrimary[url] ?? nil, size: size,
                    fingerprint: sample, sourceInfo: version, digest: nil, existing: nil,
                    ownDate: metadata[url.path]?.0, ownDateOrigin: metadata[url.path]?.1)
                file.cachedCaptureMetadata = cachedSources[url] != nil
                // Bind any reused date to the complete hash that originally established it.
                // This remains required even if the destination copy has disappeared.
                file.digest = cachedSources[url]?.hash
                if !transferred.isEmpty {
                    // A camera copy was hashed in full during transfer; reuse that hash only while
                    // the copy is unchanged, so local tampering cannot replace the camera's bytes.
                    guard let copy = transferred[url.path], copy.version.st_dev == version.st_dev, copy.version.st_ino == version.st_ino,
                        copy.version.st_size == version.st_size, copy.version.st_mtimespec.tv_sec == version.st_mtimespec.tv_sec,
                        copy.version.st_mtimespec.tv_nsec == version.st_mtimespec.tv_nsec, file.digest == nil || file.digest == copy.hash
                    else {
                        throw ImportError("A temporary camera copy changed after transfer. Scan the camera again.")
                    }
                    file.digest = copy.hash; file.transferVerified = true
                }
                if role != .sidecar {
                    var hash = file.digest
                    // Every confirmed copy matters when sidecars must be found beside one of them.
                    let found = try library.matches(
                        source: url, size: size, fingerprint: sample, hash: &hash, all: !sourceGroup.sidecars.isEmpty,
                        cancellation: cancellation, metrics: metrics, sourceDevice: version.st_dev)
                    matches[url] = found
                    file.existing = found.first
                    if found.isEmpty {
                        for peer in seen[key] ?? [] {
                            if hash == nil { hash = try digest(url, cancellation: cancellation, metrics: metrics).0 }
                            // Every earlier peer passed the transfer-hash check above.
                            if try transferred[peer.path]?.hash ?? digest(peer, cancellation: cancellation, metrics: metrics).0 == hash { file.existing = peer; break }
                        }
                    }
                    file.digest = hash
                    seen[key, default: []].append(url)
                }
                file.cachedVerification =
                    file.existing != nil && (file.cachedCaptureMetadata || library.cachedFiles.contains(url) || matches[url, default: []].contains { library.cachedFiles.contains($0) })
                guard stable(version, try info(url)) else { throw ImportError("Source changed during preview. Scan again.") }
                if let cache = verificationCache, let namespace = cacheNamespace {
                    cache.recordCaptureMetadata(url, namespace: namespace, info: version, sample: sample, day: file.ownDate, origin: file.ownDateOrigin)
                }
                indices.append(planned.count); planned.append(file)
            }
            let primaryIndices = indices.filter { planned[$0].role != .sidecar }, sidecarIndices = indices.filter { planned[$0].role == .sidecar }
            let resolution = try resolveSidecars(
                sidecarIndices.map { planned[$0] }, primaries: primaryIndices.map { planned[$0] }, matches: matches,
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
            groups.append(
                PhotoGroup(
                    id: groupID, name: first.source.deletingPathExtension().lastPathComponent, directory: first.source.deletingLastPathComponent(),
                    members: indices, date: nil, dateOrigin: "missing", folder: nil,
                    status: status(indices.map { planned[$0] }, source: source)))
        }
        if settings.otherCardCopies == .treatAsImported {
            try recognizeOtherCardCopies(
                &planned, groups: &groups, library: library, root: root, source: source, helper: helper,
                cancellation: cancellation, metrics: metrics, progress: progress)
        }
        let plan = ImportPlan(
            source: source, root: root, settings: settings, event: event, fallback: fallback, files: planned, groups: groups,
            ignored: unsupported, orphanSidecars: orphans, scanReads: metrics)
        let organized = try plan.organized(template: settings.folderTemplate, event: event, fallback: fallback)
        try cancellation.check(); verificationCache?.save()
        return organized
    }
}
