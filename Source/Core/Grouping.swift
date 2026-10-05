import Foundation

enum FileRole: String, Codable, Comparable {
    case raw, image, video, sidecar
    private var rank: Int { [.raw: 0, .image: 1, .video: 2, .sidecar: 3][self]! }
    static func < (lhs: FileRole, rhs: FileRole) -> Bool { lhs.rank < rhs.rank }
}

enum MediaTypes {
    static let raw: Set<String> = words("nef nrw gpr dng cr2 cr3 crw arw srf sr2 raf orf rw2 raw rwl pef srw x3f erf mos mef iiq 3fr fff")
    static let image: Set<String> = words("jpg jpeg jpe heic heif hif tif tiff png avif webp")
    static let video: Set<String> = words("mov mp4 m4v mts m2ts avi")
    /// Supported sidecars: XMP metadata, DxO PhotoLab (.dop), RawTherapee (.pp3), Apple Photos
    /// adjustments (.aae), camera video thumbnails (.thm), and camera voice memos (.wav).
    static let sidecar: Set<String> = words("xmp dop pp3 aae thm wav")
    static var media: Set<String> { raw.union(image).union(video) }
    static var importable: Set<String> { media.union(sidecar) }

    static func role(of url: URL) -> FileRole? {
        let ext = url.pathExtension.lowercased()
        if raw.contains(ext) { return .raw }
        if image.contains(ext) { return .image }
        if video.contains(ext) { return .video }
        if sidecar.contains(ext) { return .sidecar }
        return nil
    }
    private static func words(_ text: String) -> Set<String> { Set(text.split(separator: " ").map(String.init)) }
}

/// Related files found in one source directory.
struct SourceGroup {
    var primaries: [URL]
    /// Each sidecar, with the specific primary it names (`DSC_0001.NEF.xmp`) or nil when it
    /// shares the group's base name (`DSC_0001.xmp`).
    var sidecars: [(url: URL, primary: URL?)]
    var members: [URL] { primaries + sidecars.map(\.url) }
}

enum Grouping {
    /// Groups related originals without reading file contents.
    ///
    /// - Only files in the same directory are related, so reused camera names in other
    ///   folders stay separate.
    /// - Photos and videos sharing a base name (case-insensitive) form one group: RAW+JPEG,
    ///   RAW+HEIF, Live Photo HEIC+MOV, and similar.
    /// - A sidecar named after a complete filename (`A.NEF.xmp`, `A.NEF.dop`) belongs to that
    ///   file's group; this takes precedence. Otherwise a sidecar joins the group with its base
    ///   name (`A.xmp`). Sidecars that match no photo or video are not imported.
    static func group(_ urls: [URL]) -> (groups: [SourceGroup], orphanSidecars: [URL]) {
        var byDirectory: [String: [URL]] = [:]
        for url in urls { byDirectory[url.deletingLastPathComponent().path, default: []].append(url) }
        var groups: [SourceGroup] = [], orphans: [URL] = []
        for directory in byDirectory.keys.sorted() {
            let files = byDirectory[directory]!.sorted { $0.lastPathComponent < $1.lastPathComponent }
            var keys: [String] = [], byKey: [String: SourceGroup] = [:], primaryByName: [String: URL] = [:]
            for url in files {
                guard let role = MediaTypes.role(of: url), role != .sidecar else { continue }
                let key = url.deletingPathExtension().lastPathComponent.lowercased()
                if byKey[key] == nil { keys.append(key); byKey[key] = SourceGroup(primaries: [], sidecars: []) }
                byKey[key]!.primaries.append(url)
                primaryByName[url.lastPathComponent.lowercased()] = url
            }
            for url in files where MediaTypes.role(of: url) == .sidecar {
                let stem = url.deletingPathExtension().lastPathComponent.lowercased()
                if let primary = primaryByName[stem] {
                    byKey[primary.deletingPathExtension().lastPathComponent.lowercased()]!.sidecars.append((url, primary))
                } else if byKey[stem] != nil {
                    byKey[stem]!.sidecars.append((url, nil))
                } else {
                    orphans.append(url)
                }
            }
            for key in keys {
                var group = byKey[key]!
                group.primaries.sort { (MediaTypes.role(of: $0)!, $0.lastPathComponent) < (MediaTypes.role(of: $1)!, $1.lastPathComponent) }
                groups.append(group)
            }
        }
        return (groups, orphans)
    }

    /// The filename a sidecar should have beside an imported copy of its photo.
    static func sidecarName(_ sidecar: URL, primaryNamed: Bool, besidePrimaryNamed destinationName: String) -> String {
        let base = primaryNamed ? destinationName : (destinationName as NSString).deletingPathExtension
        return base + "." + sidecar.pathExtension
    }

    /// Inserts a collision suffix after a member's base name, keeping related files consistent:
    /// `DSC_0001.NEF` → `DSC_0001__suffix.NEF`, `DSC_0001.NEF.xmp` → `DSC_0001__suffix.NEF.xmp`.
    static func suffixed(_ name: String, suffix: String, primaryNamedSidecar: Bool) -> String {
        var base = name, extensions = ""
        for _ in 0..<(primaryNamedSidecar ? 2 : 1) {
            let ext = (base as NSString).pathExtension
            guard !ext.isEmpty else { break }
            extensions = "." + ext + extensions
            base = (base as NSString).deletingPathExtension
        }
        while base.utf8.count > 140 { base.removeLast() }
        return base + "__" + suffix + extensions
    }
}
