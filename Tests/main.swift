import Darwin
import Foundation
import ImageIO

setvbuf(stdout, nil, _IOLBF, 0)
var checks = 0
func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
    guard try condition() else { throw ImportError("FAIL: " + name) }
    checks += 1; print("PASS: " + name)
}
func rejects(_ name: String, _ body: () throws -> Void) throws {
    var rejected = false
    do { try body() } catch { rejected = true }
    try check(rejected, name)
}
let fm = FileManager.default
let testRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
let helper = MetadataHelper(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
try fm.createDirectory(at: testRoot, withIntermediateDirectories: true)
let root = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let card = root.appendingPathComponent("Card"), library = root.appendingPathComponent("Library"), reports = root.appendingPathComponent("Reports")
try fm.createDirectory(at: card, withIntermediateDirectories: true)
try fm.createDirectory(at: library, withIntermediateDirectories: true)
let cancellation = Cancellation()
func jpeg(_ name: String, day: String?, color: UInt8, in directory: URL = card, digitizedOnly: Bool = false) throws -> URL {
    let url = directory.appendingPathComponent(name)
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes: [UInt8] = [color, 70, 20, 255, color, 70, 20, 255, color, 70, 20, 255, color, 70, 20, 255]
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(
        width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    let key = digitizedOnly ? kCGImagePropertyExifDateTimeDigitized : kCGImagePropertyExifDateTimeOriginal
    let properties: [CFString: Any] = day.map { [kCGImagePropertyExifDictionary: [key: $0]] } ?? [:]
    CGImageDestinationAddImage(writer, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(writer) else { throw ImportError("Fixture generation failed") }
    return url
}
func bytes(_ url: URL) throws -> Data { try Data(contentsOf: url) }
var settings = Settings(); settings.destination = library.path; settings.folderTemplate = "{YYYY}/{MM}-{DD} - {event}"
func plan(event: String = "Soccer Tournament", fallback: CaptureDay? = nil, source: URL = card, settings: Settings = settings) throws -> ImportPlan {
    try Importer.plan(source: source, settings: settings, event: event, fallback: fallback, helper: helper, cancellation: cancellation, progress: { _ in })
}
func run(_ plan: ImportPlan, selection: Set<Int>? = nil, token: Cancellation? = nil, progress: ((ImportProgress) -> Void)? = nil) throws -> ImportResult {
    try Importer.run(plan, selection: selection, cancellation: token ?? cancellation, reportDirectory: reports, progress: progress ?? { _ in })
}
func group(_ plan: ImportPlan, _ name: String) -> PhotoGroup { plan.groups.first { $0.name == name }! }

// MARK: Bundled metadata helper
try check(
    helper.perl.path.hasPrefix(testRoot.deletingLastPathComponent().path) || helper.perl.path.contains("/build/metadata-helper/"),
    "tests use the repository-built bundled helper, not an installed ExifTool")
try check(helper.process(arguments: []).environment == ["PATH": "/usr/bin:/bin", "LC_ALL": "C"], "helper runs with a clean environment (no PERL5LIB/PERL5OPT/user config)")
try check(try helper.version() == helper.readManifest()?.components.first { $0.name == "ExifTool" }?.version, "bundled ExifTool version matches its pinned manifest")

let first = try jpeg("DSC_0001.JPG", day: "2025:05:18 23:59:59", color: 200)
let second = try jpeg("DSC_0002.JPG", day: "2025:05:19 00:00:01", color: 100)
let originalHash = try Importer.digest(first, cancellation: cancellation).0
let toolDates = try Importer.dates([first, second], helper: helper, cancellation: cancellation)
try check(toolDates[first.path]?.0 == CaptureDay(year: 2025, month: 5, day: 18), "bundled ExifTool reads real embedded capture dates")
let fallback = CaptureDay(year: 2025, month: 5, day: 18)
try check(CaptureDay.parse("2024:02:29 00:00:00") != nil && CaptureDay.parse("2025:02:29 00:00:00") == nil, "calendar validation rejects impossible dates")
try check(CaptureDay.parse("2025:05:18 23:59:59-10:00") == fallback, "camera-local day remains unchanged by timezone")
let format = try Importer.folder(template: "{YYYY}/{MM}-{DD} - {event}", event: "Soccer Tournament", date: fallback)
try check(format == "2025/05-18 - Soccer Tournament", "requested folder layout")
try rejects("event cannot escape destination") { _ = try Importer.folder(template: "{event}", event: "../escape", date: fallback) }
try rejects("template cannot escape destination") { _ = try Importer.folder(template: "../{YYYY}", event: "", date: fallback) }
try rejects("unknown template token rejected") { _ = try Importer.folder(template: "{YYYY}/{MONTH}", event: "", date: fallback) }
try rejects("event templates require an event name") { _ = try Importer.folder(template: "{YYYY}/{event}", event: "", date: fallback) }
try check(try Importer.folder(template: Settings.defaultTemplate, event: "", date: fallback) == "2025/05/18", "default year/month/day layout needs no event")
let preview = try plan()
try check(
    preview.newCount == 2 && preview.files[0].folder == "2025/05-18 - Soccer Tournament" && preview.files[1].folder == "2025/05-19 - Soccer Tournament",
    "native capture metadata and multi-day folder preview")
try check(preview.scanReads.headerBytes > 0 && preview.scanReads.hashedBytes == 0, "preview reads bounded headers and never fully hashes new originals")
let result = try run(preview)
try check(result.copied == 2 && result.skipped == 0 && result.folders.count == 2, "first import publishes two verified originals")
let saved = library.appendingPathComponent("2025/05-18 - Soccer Tournament/DSC_0001.JPG")
let savedHash = try Importer.digest(saved, cancellation: cancellation).0
let sourceHash = try Importer.digest(first, cancellation: cancellation).0
try check(savedHash == originalHash && sourceHash == originalHash, "copied bytes match and card original is untouched")
let reportDecoder = JSONDecoder(); reportDecoder.dateDecodingStrategy = .iso8601
let report = try reportDecoder.decode(Receipt.self, from: Data(contentsOf: result.receipt))
try check(report.complete && report.entries.count == 2, "successful report records hashes and destinations")
let repeatPlan = try plan(event: "Different Event")
try check(repeatPlan.newCount == 0 && repeatPlan.newGroups.isEmpty, "existing files detected across different event folders")
let repeatResult = try run(repeatPlan)
try check(repeatResult.copied == 0 && repeatResult.skipped == 2 && repeatResult.folders.isEmpty, "repeat import creates no new folders or copies")
try fm.moveItem(at: saved, to: library.appendingPathComponent("renamed-original.without-a-photo-extension"))
let renamePlan = try plan()
try check(renamePlan.newCount == 0, "renamed originals still count as already imported")
try fm.removeItem(at: first)
let conflicting = try jpeg("DSC_0001.JPG", day: "2025:05:18 10:00:00", color: 20)
try Data("different original already here".utf8).write(to: saved)
let conflictResult = try run(plan())
try check(conflictResult.copied == 1 && (try? Data(contentsOf: saved)) == Data("different original already here".utf8), "same filename with different contents never overwrites")
let names = try fm.contentsOfDirectory(atPath: saved.deletingLastPathComponent().path)
try check(names.contains(where: { $0.hasPrefix("DSC_0001__") }), "filename collision receives hash suffix")
let noDate = try jpeg("missing.JPG", day: nil, color: 240)
let missingPlan = try plan()
try check(missingPlan.missingCount == 1, "missing capture dates are surfaced")
try rejects("missing dates block copying without explicit fallback") { _ = try run(missingPlan) }
let datedOnly = Set(missingPlan.groups.filter { $0.date != nil }.map(\.id))
try check(missingPlan.missingDates(in: datedOnly) == 0, "a selection without undated photos does not need a fallback")
let fallbackPlan = try plan(fallback: fallback)
try check(fallbackPlan.missingCount == 0 && fallbackPlan.files.first(where: { $0.source == noDate })?.dateOrigin == "user-selected date", "explicit date fallback is recorded")
let modifiedPlan = fallbackPlan
try Data("changed after preview".utf8).write(to: noDate)
try rejects("source changed after preview is refused") { _ = try run(modifiedPlan) }
try fm.removeItem(at: noDate)
let cancelled = Cancellation(); cancelled.cancel()
try rejects("cancel before copying is safe") { _ = try run(plan(), token: cancelled) }
let escape = root.appendingPathComponent("Escape")
try fm.createDirectory(at: escape, withIntermediateDirectories: false)
try fm.createSymbolicLink(at: library.appendingPathComponent("2027"), withDestinationURL: escape)
try rejects("symlink destination folder is refused") { _ = try Importer.makeFolder(root: library, relative: "2027/01-01 - Event") }
try rejects("missing destination is not silently created") { try Importer.validateLocations(source: card, root: root.appendingPathComponent("Absent")) }
try rejects("source and destination cannot overlap") { try Importer.validateLocations(source: card, root: root) }
// On case-insensitive volumes (the macOS default and camera cards), CARD names the source itself.
try rejects("overlap check ignores letter case") { try Importer.validateLocations(source: card, root: root.appendingPathComponent("CARD")) }
let lockPath = library.appendingPathComponent(".photo-import.lock")
let lockFD = open(lockPath.path, O_RDWR | O_CREAT, 0o600); _ = flock(lockFD, LOCK_EX | LOCK_NB)
try rejects("concurrent import is blocked") { _ = try run(plan()) }
_ = flock(lockFD, LOCK_UN); close(lockFD)
// Remove the matched original after preview. The import must create a new verified copy.
let removedPlan = try plan()
if let existing = removedPlan.files.first(where: { $0.source == second })?.existing { try fm.removeItem(at: existing) }
let recovered = try run(removedPlan)
try check(recovered.copied == 1, "removed duplicate after preview is recopied safely")
let third = try jpeg("third.JPG", day: "2025:05:20 12:00:00", color: 33)
let finalPlan = try plan()
let finalTarget = library.appendingPathComponent("2025/05-20 - Soccer Tournament/third.JPG")
var tampered = false
try rejects("final verification catches changed destination") {
    _ = try run(
        finalPlan,
        progress: { update in
            if !tampered && update.text.hasPrefix("Final verification:") { try? Data("tampered".utf8).write(to: finalTarget); tampered = true }
        })
}
let partials = try Importer.files(in: library, allowed: nil, cancellation: cancellation).0.filter { $0.pathExtension == "partial" }
try check(partials.isEmpty, "failed and cancelled imports leave no visible partial copies")
try check(fm.fileExists(atPath: third.path) && fm.fileExists(atPath: conflicting.path), "failure leaves card originals present")
// Byte-preservation fixtures exercise RAW extensions without pretending to be real camera metadata samples.
try fm.removeItem(at: third)
for (name, bytes) in [("Synthetic.NEF", Data([0, 7, 11, 255, 3])), ("Synthetic.GPR", Data([0, 9, 12, 254, 4, 8]))] {
    try bytes.write(to: card.appendingPathComponent(name))
}
let rawPlan = try plan(fallback: fallback)
let rawResult = try run(rawPlan)
try check(rawResult.copied == 2, "NEF and GPR extensions are imported with explicit fallback dates")
for name in ["Synthetic.NEF", "Synthetic.GPR"] {
    let sourceBytes = try Data(contentsOf: card.appendingPathComponent(name))
    let destinationBytes = try Data(contentsOf: library.appendingPathComponent("2025/05-18 - Soccer Tournament/" + name))
    try check(sourceBytes == destinationBytes, "\(name) container bytes are preserved without conversion")
}
let rawRepeat = try plan(fallback: fallback)
try check(rawRepeat.newCount == 0, "RAW container duplicates are skipped on repeat scans")

// MARK: Packaged metadata fallback
// ImageIO's bounded read only accepts DateTimeOriginal; this file has only CreateDate,
// so its date can only come from the bundled ExifTool fallback.
let fallbackCard = root.appendingPathComponent("FallbackCard")
let digitized = try jpeg("DIGITIZED.JPG", day: "2024:12:31 18:30:00", color: 90, in: fallbackCard, digitizedOnly: true)
let digitizedPlan = try plan(source: fallbackCard)
let digitizedFile = digitizedPlan.files.first { $0.source == digitized }!
try check(digitizedFile.date == CaptureDay(year: 2024, month: 12, day: 31) && digitizedFile.dateOrigin == "ExifIFD:CreateDate", "bundled ExifTool supplies dates ImageIO's bounded read cannot")
let broken = MetadataHelper(directory: root.appendingPathComponent("NoHelper"))
try rejects("a missing bundled helper stops the scan instead of searching elsewhere") {
    _ = try Importer.plan(source: fallbackCard, settings: settings, event: "x", fallback: nil, helper: broken, cancellation: cancellation, progress: { _ in })
}

// MARK: Related-file grouping
let groupCard = root.appendingPathComponent("GroupCard"), groupLibrary = root.appendingPathComponent("GroupLibrary")
try fm.createDirectory(at: groupLibrary, withIntermediateDirectories: true)
let folder100 = groupCard.appendingPathComponent("DCIM/100CAMERA"), folder101 = groupCard.appendingPathComponent("DCIM/101CAMERA")
let pairJPEG = try jpeg("IMG_0001.JPG", day: "2025:06:01 09:00:00", color: 10, in: folder100)
let pairRAW = folder100.appendingPathComponent("IMG_0001.CR3"); try Data([1, 2, 3, 4, 5, 6]).write(to: pairRAW)
try Data("<x:xmpmeta rating=5/>".utf8).write(to: folder100.appendingPathComponent("IMG_0001.xmp"))
try Data("dxo settings for raw".utf8).write(to: folder100.appendingPathComponent("IMG_0001.CR3.dop"))
try Data("orphan".utf8).write(to: folder100.appendingPathComponent("IMG_0099.xmp"))
_ = try jpeg("img_0002.jpg", day: "2025:06:02 10:00:00", color: 11, in: folder100)
try Data([9, 9, 9, 9]).write(to: folder100.appendingPathComponent("IMG_0002.NEF"))
let reused = try jpeg("IMG_0001.JPG", day: "2025:06:03 11:00:00", color: 12, in: folder101)
let video = folder101.appendingPathComponent("MVI_0003.MOV"); try Data([0, 0, 0, 8, 1, 2, 3, 4]).write(to: video)
try Data([7, 7, 7]).write(to: folder101.appendingPathComponent("MVI_0003.THM"))
let grouped = Grouping.group(try Importer.files(in: groupCard, allowed: MediaTypes.importable, cancellation: cancellation).0)
try check(grouped.groups.count == 4, "RAW+JPEG pairs, case-insensitive pairs, video+THM, and reused names form four groups")
let pairGroup = grouped.groups.first { $0.primaries.contains(pairRAW) }!
try check(pairGroup.primaries == [pairRAW, pairJPEG] && pairGroup.sidecars.count == 2, "RAW is the group's lead file and both sidecars attach")
try check(pairGroup.sidecars.first { $0.url.lastPathComponent == "IMG_0001.CR3.dop" }?.primary == pairRAW, "a full-filename sidecar names its specific photo")
try check(!pairGroup.primaries.contains(reused), "reused names in another directory stay separate")
try check(grouped.orphanSidecars.map(\.lastPathComponent) == ["IMG_0099.xmp"], "sidecars without a photo are reported and not imported")
var groupSettings = Settings(); groupSettings.destination = groupLibrary.path
try check(groupSettings.launchInBackground && groupSettings.cardInsertion == .scanInBackground, "new users launch quietly and scan cards in the background")
try check(groupSettings.folderTemplate == "{YYYY}/{MM}/{DD}", "new settings default to year/month/day")
let groupPlan = try plan(event: "", source: groupCard, settings: groupSettings)
try check(groupPlan.groups.count == 4 && groupPlan.files.count == 9 && groupPlan.orphanSidecars.count == 1, "photo-group and physical-file counts are distinct")
let rawMember = groupPlan.files.first { $0.source == pairRAW }!
try check(rawMember.date == CaptureDay(year: 2025, month: 6, day: 1) && rawMember.dateOrigin.hasPrefix("from IMG_0001.JPG"), "an undated RAW inherits its JPEG companion's capture day and records why")
try check(
    Set(groupPlan.groups.compactMap(\.folder)) == ["2025/06/01", "2025/06/02", "2025/06/03"] && groupPlan.members(groupPlan.groups[0]).allSatisfy { $0.folder == "2025/06/01" },
    "related files share one folder; multi-date imports use one folder per day")
let videoGroup = groupPlan.groups.first { $0.directory.lastPathComponent == "101CAMERA" && $0.name == "MVI_0003" }!
try check(videoGroup.date == nil && groupPlan.missingDates(in: [videoGroup.id]) == 2, "an undated group needs an explicit fallback for every member")
try check(groupPlan.newGroups.count == 4, "new photo groups are selected by default")
let reorganized = try groupPlan.organized(template: "{YYYY}-{MM}-{DD} {event}", event: "Trip", fallback: fallback)
try check(
    reorganized.groups[0].folder == "2025-06-01 Trip" && reorganized.missingCount == 0 && reorganized.scanReads === groupPlan.scanReads,
    "changing structure, event, or fallback recomputes folders without rereading files")

// MARK: Selection
let firstDay = groupPlan.groups[0].id
let subset = try run(groupPlan, selection: [firstDay])
let firstDayFolder = groupLibrary.appendingPathComponent("2025/06/01")
try check(
    subset.copied == 4 && Set(try fm.contentsOfDirectory(atPath: firstDayFolder.path)) == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001.xmp", "IMG_0001.CR3.dop"],
    "importing a selected group copies every member with original names")
try check(!fm.fileExists(atPath: groupLibrary.appendingPathComponent("2025/06/02").path), "unselected groups are not copied")
for member in groupPlan.members(groupPlan.groups[0]) {
    try check(try bytes(member.source) == bytes(firstDayFolder.appendingPathComponent(member.source.lastPathComponent)), "\(member.source.lastPathComponent) bytes match exactly")
}
let afterSubset = groupPlan.applying(subset.outcomes)
try check(afterSubset.groups[0].status == .imported && afterSubset.newGroups.count == 3, "verified results update the preview without a rescan")
let groupRepeat = try plan(event: "", source: groupCard, settings: groupSettings)
try check(groupRepeat.groups[0].status == .imported && groupRepeat.newGroups.count == 3, "rescan recognizes imported groups, including sidecars beside their photo")

// MARK: Partial duplicates
let partialFolder = groupCard.appendingPathComponent("DCIM/102CAMERA")
let partialJPEG = try jpeg("DSC_5000.JPG", day: "2025:07:04 08:00:00", color: 44, in: partialFolder)
let partialRAW = partialFolder.appendingPathComponent("DSC_5000.NEF"); try Data([5, 0, 0, 0, 1]).write(to: partialRAW)
try fm.createDirectory(at: groupLibrary.appendingPathComponent("Older"), withIntermediateDirectories: true)
try fm.copyItem(at: partialJPEG, to: groupLibrary.appendingPathComponent("Older/renamed-jpeg.jpg"))
let partialPlan = try plan(event: "", source: groupCard, settings: groupSettings)
let partialGroup = group(partialPlan, "DSC_5000")
try check(partialGroup.status == .partial && partialPlan.newGroups.contains(partialGroup.id), "a group with an imported JPEG and a new RAW is partial and selected")
let partialResult = try run(partialPlan, selection: [partialGroup.id])
try check(
    partialResult.copied == 1 && partialResult.skipped == 1 && fm.fileExists(atPath: groupLibrary.appendingPathComponent("2025/07/04/DSC_5000.NEF").path)
        && !fm.fileExists(atPath: groupLibrary.appendingPathComponent("2025/07/04/DSC_5000.JPG").path), "only the missing member of a partial group is copied")
// A sidecar edited outside the app no longer matches; it is not new photo content.
try Data("<x:xmpmeta rating=1/>".utf8).write(to: folder100.appendingPathComponent("IMG_0001.xmp"))
let sidecarPlan = try plan(event: "", source: groupCard, settings: groupSettings)
let changedSidecar = group(sidecarPlan, "IMG_0001")
try check(
    changedSidecar.directory.lastPathComponent == "100CAMERA" && changedSidecar.status == .sidecarChanged && !sidecarPlan.newGroups.contains(changedSidecar.id),
    "a group whose only change is a sidecar is not selected by default")

// MARK: Group collisions
let collisionCard = root.appendingPathComponent("CollisionCard"), collisionFolder = groupLibrary.appendingPathComponent("2025/08/09")
let collidingJPEG = try jpeg("DSC_7000.JPG", day: "2025:08:09 12:00:00", color: 77, in: collisionCard)
try Data([7, 0, 0, 7]).write(to: collisionCard.appendingPathComponent("DSC_7000.NEF"))
try Data("sidecar".utf8).write(to: collisionCard.appendingPathComponent("DSC_7000.NEF.xmp"))
try fm.createDirectory(at: collisionFolder, withIntermediateDirectories: true)
try Data("an unrelated photo from another camera".utf8).write(to: collisionFolder.appendingPathComponent("DSC_7000.NEF"))
let collisionPlan = try plan(event: "", source: collisionCard, settings: groupSettings)
let collisionResult = try run(collisionPlan)
let collisionNames = Set(try fm.contentsOfDirectory(atPath: collisionFolder.path))
let suffixes = Set(collisionNames.filter { $0.hasPrefix("DSC_7000__") }.map { $0.dropFirst("DSC_7000__".count).prefix(16) })
try check(collisionResult.copied == 3 && suffixes.count == 1 && collisionNames.filter { $0.hasPrefix("DSC_7000__") }.count == 3, "a name collision gives every related file the same suffix")
try check(
    collisionNames.contains { $0.hasPrefix("DSC_7000__") && $0.hasSuffix(".NEF.xmp") }
        && (try? Data(contentsOf: collisionFolder.appendingPathComponent("DSC_7000.NEF"))) == Data("an unrelated photo from another camera".utf8),
    "the full-filename sidecar keeps its photo's name and the existing file is untouched")
try check(!collisionResult.notes.isEmpty, "collision renames are reported")
let collisionRepeat = try plan(event: "", source: collisionCard, settings: groupSettings)
try check(collisionRepeat.groups[0].status == .imported, "suffixed groups, including their sidecars, are recognized on rescan")
_ = collidingJPEG

// MARK: Changed and missing sidecars beside imported photos
let sideCard = root.appendingPathComponent("SidecarCard"), sideLibrary = root.appendingPathComponent("SidecarLibrary")
try fm.createDirectory(at: sideLibrary, withIntermediateDirectories: true)
var sideSettings = Settings(); sideSettings.destination = sideLibrary.path
_ = try jpeg("DSC_8000.JPG", day: "2025:10:01 09:00:00", color: 81, in: sideCard)
try Data([8, 0, 0, 0, 1]).write(to: sideCard.appendingPathComponent("DSC_8000.NEF"))
let changedXMP = sideCard.appendingPathComponent("DSC_8000.xmp"); try Data("<rating>1</rating>".utf8).write(to: changedXMP)
_ = try jpeg("DSC_8001.JPG", day: "2025:10:01 10:00:00", color: 82, in: sideCard)
let missingXMP = sideCard.appendingPathComponent("DSC_8001.JPG.xmp"); try Data("<label>red</label>".utf8).write(to: missingXMP)
try Data([8, 0, 0, 0, 2]).write(to: sideCard.appendingPathComponent("UNDATED.NEF"))
let undatedXMP = sideCard.appendingPathComponent("UNDATED.xmp"); try Data("<rating>2</rating>".utf8).write(to: undatedXMP)
let sideFirst = try Importer.plan(source: sideCard, settings: sideSettings, event: "", fallback: fallback, helper: helper, cancellation: cancellation, progress: { _ in })
try check(try run(sideFirst).copied == 7, "sidecar fixtures import with their photos")
let sideFolder = sideLibrary.appendingPathComponent("2025/10/01"), undatedFolder = sideLibrary.appendingPathComponent("2025/05/18")
// Edit the destination sidecar (as an editor would), change the card's version, and remove another sidecar.
try Data("<rating>5</rating> edited in the destination".utf8).write(to: sideFolder.appendingPathComponent("DSC_8000.xmp"))
try Data("<rating>3</rating> changed on the card".utf8).write(to: changedXMP)
try fm.removeItem(at: sideFolder.appendingPathComponent("DSC_8001.JPG.xmp"))
try Data("<rating>4</rating> changed on the card".utf8).write(to: undatedXMP)
let sidePlan = try Importer.plan(source: sideCard, settings: sideSettings, event: "", fallback: nil, helper: helper, cancellation: cancellation, progress: { _ in })
let changedGroup = group(sidePlan, "DSC_8000"), missingGroup = group(sidePlan, "DSC_8001"), undatedGroup = group(sidePlan, "UNDATED")
try check([changedGroup, missingGroup, undatedGroup].allSatisfy { $0.status == .sidecarChanged } && sidePlan.newGroups.isEmpty, "changed or missing sidecars are shown but not selected by default")
try check(sidePlan.missingDates(in: [undatedGroup.id]) == 0, "an undated sidecar-only import needs no date: it goes beside its imported photo")
let sideResult = try run(sidePlan, selection: [changedGroup.id, missingGroup.id, undatedGroup.id])
let sideNames = Set(try fm.contentsOfDirectory(atPath: sideFolder.path))
try check(
    (try? String(contentsOf: sideFolder.appendingPathComponent("DSC_8000.xmp"), encoding: .utf8)) == "<rating>5</rating> edited in the destination", "the edited destination sidecar is never replaced")
let companions = sideNames.filter { $0.hasPrefix("DSC_8000__") }
let companionStems = Set(companions.map { $0.components(separatedBy: ".")[0] })
try check(
    companions.count == 3 && companionStems.count == 1 && companions.contains { $0.hasSuffix(".NEF") } && companions.contains { $0.hasSuffix(".JPG") } && companions.contains { $0.hasSuffix(".xmp") },
    "a changed sidecar is imported with a matching copy of its photos under one shared name")
let companionXMP = sideFolder.appendingPathComponent(companions.first { $0.hasSuffix(".xmp") }!)
try check(
    try bytes(companionXMP) == bytes(changedXMP)
        && (try bytes(sideFolder.appendingPathComponent(companions.first { $0.hasSuffix(".NEF") }!))) == (try bytes(sideCard.appendingPathComponent("DSC_8000.NEF"))),
    "companion copies are byte-identical to the card")
try check(try bytes(sideFolder.appendingPathComponent("DSC_8001.JPG.xmp")) == bytes(missingXMP), "a missing sidecar is restored beside its photo under its associated name")
let undatedCompanions = try fm.contentsOfDirectory(atPath: undatedFolder.path).filter { $0.hasPrefix("UNDATED__") }
try check(undatedCompanions.count == 2, "an undated changed sidecar is imported beside its photo without a fallback date")
try check(sideResult.copied == 6 && !sideResult.notes.isEmpty, "only the sidecars and the photo copies they need are created, and the result explains why")
let sideRescan = try Importer.plan(source: sideCard, settings: sideSettings, event: "", fallback: nil, helper: helper, cancellation: cancellation, progress: { _ in })
try check(sideRescan.groups.allSatisfy { $0.status == .imported }, "rescan recognizes changed and restored sidecars beside their photos")
let sideRepeat = try run(sideRescan, selection: Set(sideRescan.groups.map(\.id)))
let afterRepeat = try Importer.files(in: sideLibrary, allowed: nil, cancellation: cancellation).0.count
try check(sideRepeat.copied == 0 && afterRepeat == 12, "repeating an identical import creates zero additional copies")

// MARK: Sidecars beside photos directly in the destination root
let rootCard = root.appendingPathComponent("RootCard"), rootLibrary = root.appendingPathComponent("RootLibrary")
try fm.createDirectory(at: rootLibrary, withIntermediateDirectories: true)
var rootSettings = Settings(); rootSettings.destination = rootLibrary.path
let rootPhotoA = try jpeg("ROOT_1.JPG", day: "2025:11:01 09:00:00", color: 91, in: rootCard)
let rootPhotoB = try jpeg("ROOT_2.JPG", day: "2025:11:01 10:00:00", color: 92, in: rootCard)
let rootMissing = rootCard.appendingPathComponent("ROOT_1.xmp"); try Data("<label>root missing</label>".utf8).write(to: rootMissing)
let rootChanged = rootCard.appendingPathComponent("ROOT_2.xmp"); try Data("<rating>2</rating> card version".utf8).write(to: rootChanged)
// Photos placed straight into the root earlier, for example by another tool.
try fm.copyItem(at: rootPhotoA, to: rootLibrary.appendingPathComponent("ROOT_1.JPG"))
try fm.copyItem(at: rootPhotoB, to: rootLibrary.appendingPathComponent("ROOT_2.JPG"))
let rootEdited = Data("<rating>5</rating> edited in the destination".utf8)
try rootEdited.write(to: rootLibrary.appendingPathComponent("ROOT_2.xmp"))
let rootPlan = try plan(event: "", source: rootCard, settings: rootSettings)
let rootSidecars = rootPlan.files.filter { $0.role == .sidecar }
try check(
    rootPlan.groups.allSatisfy { $0.status == .sidecarChanged } && rootSidecars.allSatisfy { $0.besideDirectory?.standardizedFileURL.path == rootLibrary.standardizedFileURL.path }
        && rootPlan.missingDates(in: Set(rootPlan.groups.map(\.id))) == 0, "sidecars of photos directly in the destination root are placed in the root")
let rootResult = try run(rootPlan, selection: Set(rootPlan.groups.map(\.id)))
let rootNames = try fm.contentsOfDirectory(atPath: rootLibrary.path).filter { !$0.hasPrefix(".") }
let rootCompanions = rootNames.filter { $0.hasPrefix("ROOT_2__") }
try check(rootResult.copied == 3 && (try bytes(rootLibrary.appendingPathComponent("ROOT_1.xmp"))) == (try bytes(rootMissing)), "a missing sidecar is restored beside its root-level photo")
try check(
    try bytes(rootLibrary.appendingPathComponent("ROOT_2.xmp")) == rootEdited && rootCompanions.count == 2 && Set(rootCompanions.map { $0.components(separatedBy: ".")[0] }).count == 1
        && (try bytes(rootLibrary.appendingPathComponent(rootCompanions.first { $0.hasSuffix(".xmp") }!))) == (try bytes(rootChanged)),
    "a changed root-level sidecar keeps the edited file and arrives with a matching photo copy")
let rootRescan = try plan(event: "", source: rootCard, settings: rootSettings)
let rootRepeat = try run(rootRescan, selection: Set(rootRescan.groups.map(\.id)))
try check(
    rootRescan.groups.allSatisfy { $0.status == .imported } && rootRepeat.copied == 0
        && (try fm.contentsOfDirectory(atPath: rootLibrary.path).filter { !$0.hasPrefix(".") }.count) == 6, "root-level sidecars are recognized on rescan and a repeat copies nothing")
try check((try? Importer.validatePlacement(rootLibrary, root: rootLibrary)) != nil, "the destination root itself is a valid placement folder")
try rejects("a placement outside the destination is refused") { try Importer.validatePlacement(rootCard, root: rootLibrary) }
let lookAlike = root.appendingPathComponent("RootLibrary2"); try fm.createDirectory(at: lookAlike, withIntermediateDirectories: true)
try rejects("a sibling folder sharing the root's name prefix is refused") { try Importer.validatePlacement(lookAlike, root: rootLibrary) }
let linkedPlacement = rootLibrary.appendingPathComponent("Linked"); try fm.createSymbolicLink(at: linkedPlacement, withDestinationURL: rootCard)
try rejects("a symlinked placement folder inside the root is refused") { try Importer.validatePlacement(linkedPlacement, root: rootLibrary) }
try fm.removeItem(at: linkedPlacement)

// MARK: A group with two placements where the second one fails or is cancelled
let twoCard = root.appendingPathComponent("TwoPlacementCard"), twoLibrary = root.appendingPathComponent("TwoPlacementLibrary")
try fm.createDirectory(at: twoLibrary, withIntermediateDirectories: true)
var twoSettings = Settings(); twoSettings.destination = twoLibrary.path
_ = try jpeg("TWO_1.JPG", day: "2025:11:02 09:00:00", color: 93, in: twoCard)
try Data([2, 2, 2, 2, 9]).write(to: twoCard.appendingPathComponent("TWO_1.NEF"))
let jpegSidecar = twoCard.appendingPathComponent("TWO_1.JPG.xmp"), rawSidecar = twoCard.appendingPathComponent("TWO_1.NEF.xmp")
try Data("<label>jpeg</label>".utf8).write(to: jpegSidecar); try Data("<label>raw</label>".utf8).write(to: rawSidecar)
try check(try run(plan(event: "", source: twoCard, settings: twoSettings)).copied == 4, "two-placement fixture imports")
// Keep the RAW in its own folder and remove both sidecars from the destination.
let twoDay = twoLibrary.appendingPathComponent("2025/11/02"), rawFolder = twoLibrary.appendingPathComponent("RAW")
try fm.createDirectory(at: rawFolder, withIntermediateDirectories: true)
try fm.moveItem(at: twoDay.appendingPathComponent("TWO_1.NEF"), to: rawFolder.appendingPathComponent("TWO_1.NEF"))
let rawBefore = try bytes(rawFolder.appendingPathComponent("TWO_1.NEF")), jpegBefore = try bytes(twoDay.appendingPathComponent("TWO_1.JPG"))
func removeDestinationSidecars() throws {
    for url in [twoDay.appendingPathComponent("TWO_1.JPG.xmp"), rawFolder.appendingPathComponent("TWO_1.NEF.xmp")] where fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
}
try removeDestinationSidecars()
func partialFiles() throws -> [String] { try fm.subpathsOfDirectory(atPath: twoLibrary.path).filter { $0.hasSuffix(".partial") } }
func checkFirstPlacementKept(_ failure: ImportFailure?, cancelled: Bool, _ label: String) throws {
    let receipt = try failure.map { try reportDecoder.decode(Receipt.self, from: Data(contentsOf: $0.receipt)) }
    let placed = twoDay.appendingPathComponent("TWO_1.JPG.xmp")
    try check(
        failure?.cancelled == cancelled && failure?.copied == 1 && failure?.skipped == 2 && failure?.outcomes[jpegSidecar.path] == placed
            && failure?.outcomes.count == 3 && failure?.outcomes[rawSidecar.path] == nil, "\(label): the failure reports the first placement and the verified photos")
    try check(
        receipt.map {
            !$0.complete && $0.cancelled == cancelled && $0.error != nil && $0.entries.count == 3
                && $0.entries.contains { $0.destination == placed.path && $0.action == "copied and verified" }
        } == true, "\(label): the receipt records every published and verified file")
    try check(
        try bytes(placed) == bytes(jpegSidecar) && !fm.fileExists(atPath: rawFolder.appendingPathComponent("TWO_1.NEF.xmp").path)
            && (try bytes(rawFolder.appendingPathComponent("TWO_1.NEF"))) == rawBefore && (try bytes(twoDay.appendingPathComponent("TWO_1.JPG"))) == jpegBefore
            && (try partialFiles()).isEmpty, "\(label): the published sidecar and existing photos keep their bytes and no staging file remains")
}
func retryCompletes(_ label: String) throws {
    let retryPlan = try plan(event: "", source: twoCard, settings: twoSettings)
    let retry = try run(retryPlan, selection: Set(retryPlan.groups.map(\.id)))
    let after = try plan(event: "", source: twoCard, settings: twoSettings)
    try check(
        retry.copied == 1 && (try bytes(rawFolder.appendingPathComponent("TWO_1.NEF.xmp"))) == (try bytes(rawSidecar))
            && after.groups.allSatisfy { $0.status == .imported } && (try run(after, selection: Set(after.groups.map(\.id)))).copied == 0,
        "\(label): retry places only the remaining sidecar, then repeats copy nothing")
}
let twoPlan = try plan(event: "", source: twoCard, settings: twoSettings)
try check(Set(twoPlan.files.compactMap { $0.besideDirectory?.lastPathComponent }) == ["02", "RAW"], "each sidecar is placed beside its own photo, in two folders")
// Second placement fails while staging: its folder cannot be written.
chmod(rawFolder.path, 0o555)
var stagingFailure: ImportFailure?
do { _ = try run(twoPlan, selection: Set(twoPlan.groups.map(\.id))) } catch let error as ImportFailure { stagingFailure = error }
chmod(rawFolder.path, 0o755)
try checkFirstPlacementKept(stagingFailure, cancelled: false, "staging failure")
try retryCompletes("after a staging failure")
// Second placement is cancelled after the first has been published.
try removeDestinationSidecars()
let cancelPlan = try plan(event: "", source: twoCard, settings: twoSettings)
let placementStop = Cancellation()
var cancelledFailure: ImportFailure?
do {
    _ = try run(
        cancelPlan, selection: Set(cancelPlan.groups.map(\.id)), token: placementStop,
        progress: { update in if update.text.hasPrefix("Placing TWO_1.NEF.xmp") { placementStop.cancel() } })
} catch let error as ImportFailure { cancelledFailure = error }
try checkFirstPlacementKept(cancelledFailure, cancelled: true, "cancellation")
try retryCompletes("after cancellation")

// MARK: Interruption and retry
let interruptCard = root.appendingPathComponent("InterruptCard"), interruptLibrary = root.appendingPathComponent("InterruptLibrary")
try fm.createDirectory(at: interruptLibrary, withIntermediateDirectories: true)
for index in 0..<4 { _ = try jpeg("INT_\(index).JPG", day: "2025:09:0\(index + 1) 12:00:00", color: UInt8(150 + index), in: interruptCard) }
var interruptSettings = Settings(); interruptSettings.destination = interruptLibrary.path
let interruptPlan = try plan(event: "", source: interruptCard, settings: interruptSettings)
let stopper = Cancellation()
var failure: ImportFailure?
do {
    _ = try run(interruptPlan, token: stopper, progress: { update in if update.text.hasPrefix("Importing 3 of") { stopper.cancel() } })
} catch let error as ImportFailure { failure = error }
try check(failure?.cancelled == true && failure?.copied == 2 && failure?.outcomes.count == 2, "cancellation reports exactly the verified copies kept")
let interruptReport = try reportDecoder.decode(Receipt.self, from: Data(contentsOf: failure!.receipt))
try check(!interruptReport.complete && interruptReport.cancelled && interruptReport.entries.count == 2, "the report records a cancelled, partial import")
try check(
    try Importer.files(in: interruptLibrary, allowed: nil, cancellation: cancellation).0.count == 2
        && (try fm.subpathsOfDirectory(atPath: interruptLibrary.path)).allSatisfy { !$0.hasSuffix(".partial") }, "cancellation keeps completed copies and removes the in-progress staging file")
let retryPlan = try plan(event: "", source: interruptCard, settings: interruptSettings)
try check(retryPlan.newGroups.count == 2, "rescan after cancellation offers only the remaining photos")
let retry = try run(retryPlan, selection: retryPlan.newGroups)
try check(retry.copied == 2 && (try Importer.files(in: interruptLibrary, allowed: nil, cancellation: cancellation).0.count) == 4, "retry completes the import without duplicates")

// MARK: Undated duplicates within one source
let twinCard = root.appendingPathComponent("TwinCard")
let twinA = try jpeg("TWIN.JPG", day: nil, color: 61, in: twinCard.appendingPathComponent("A"))
try fm.createDirectory(at: twinCard.appendingPathComponent("B"), withIntermediateDirectories: true)
try fm.copyItem(at: twinA, to: twinCard.appendingPathComponent("B/TWIN-COPY.JPG"))
let twinPlan = try plan(event: "", source: twinCard, settings: groupSettings)
try check(
    twinPlan.groups.contains { $0.status == .sourceDuplicate } && twinPlan.missingDates(in: Set(twinPlan.groups.map(\.id))) == 2,
    "undated duplicates within a source still require a fallback before import")
try rejects("an undated duplicate within the source is refused before any copy") { _ = try run(twinPlan) }

// MARK: Settings migration
let settingsRoot = root.appendingPathComponent("Settings"), legacyRoot = root.appendingPathComponent("LegacySettings")
try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
let legacyJSON =
    #"{"destination":"/Volumes/Photography/Photo Container","eject":true,"exiftool":"/opt/homebrew/bin/exiftool","folderTemplate":"{YYYY}/{MM}-{DD} - {event}","openInDxO":true,"photoLab":"/Applications/DXOPhotoLab10.app"}"#
try Data(legacyJSON.utf8).write(to: legacyRoot.appendingPathComponent("settings.json"))
let migrated = Settings.load(directory: settingsRoot, legacyDirectories: [legacyRoot])
try check(
    migrated.destination == "/Volumes/Photography/Photo Container" && migrated.folderTemplate == "{YYYY}/{MM}-{DD} - {event}" && migrated.eject && migrated.openInDxO,
    "prototype settings keep the configured destination, template, and completion options")
try check(
    migrated.launchInBackground && migrated.cardInsertion == .showAndScan && migrated.presets.isEmpty && migrated.schemaVersion == Settings.schema,
    "fields missing from prototype settings use new defaults")
try check(
    fm.fileExists(atPath: settingsRoot.appendingPathComponent("settings.json").path) && (try Data(contentsOf: legacyRoot.appendingPathComponent("settings.json"))) == Data(legacyJSON.utf8),
    "migration writes the new location and leaves the prototype file untouched")
let fresh = Settings.load(directory: root.appendingPathComponent("FreshSettings"), legacyDirectories: [root.appendingPathComponent("NoLegacy")])
try check(fresh.destination == fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].path && fresh.folderTemplate == "{YYYY}/{MM}/{DD}", "new users default to Pictures and year/month/day")
var customized = migrated
customized.cardInsertion = .scanInBackground
customized.launchInBackground = false
customized.presets = [ImportPreset(name: "Trips", destination: library.path, folderTemplate: "{YYYY}/{event}", openInEditor: false, eject: true)]
try customized.save(to: settingsRoot)
let reloaded = Settings.load(directory: settingsRoot, legacyDirectories: [legacyRoot])
try check(
    reloaded.cardInsertion == .scanInBackground && !reloaded.launchInBackground && reloaded.presets == customized.presets && reloaded.destination == customized.destination,
    "startup, background scanning, and saved presets persist")
try Data("{not json".utf8).write(to: settingsRoot.appendingPathComponent("settings.json"))
let recoveredSettings = Settings.load(directory: settingsRoot, legacyDirectories: [legacyRoot])
try check(
    recoveredSettings.folderTemplate == Settings.defaultTemplate && (try fm.contentsOfDirectory(atPath: settingsRoot.path)).contains { $0.hasPrefix("settings-unreadable-") },
    "an unreadable settings file is preserved before defaults are used")
let renamedRoot = root.appendingPathComponent("RenamedSettings"), previousNameRoot = root.appendingPathComponent("PreviousNameSettings")
try customized.save(to: previousNameRoot)
let previousNameJSON = try Data(contentsOf: previousNameRoot.appendingPathComponent("settings.json"))
let renamed = Settings.load(directory: renamedRoot, legacyDirectories: [previousNameRoot, legacyRoot])
try check(renamed.presets == customized.presets && !renamed.launchInBackground && renamed.cardInsertion == .scanInBackground, "the previous app name's settings win over the prototype's")
try check(
    (try Data(contentsOf: previousNameRoot.appendingPathComponent("settings.json"))) == previousNameJSON
        && (try Data(contentsOf: legacyRoot.appendingPathComponent("settings.json"))) == Data(legacyJSON.utf8), "renaming leaves earlier settings files untouched")
try check(
    Settings.directory.lastPathComponent == "Corvus" && Settings.legacyDirectories.map(\.lastPathComponent) == ["Andermic Photo Importer", "Photo Import"]
        && Settings.reportsDirectory.deletingLastPathComponent() == Settings.directory, "settings and reports live in Corvus and adopt the previous name's folder before the prototype's")

// MARK: Bounded preview reads
// Cold-scan workload: large new originals among same-size unrelated destination files.
let perfCard = root.appendingPathComponent("PerformanceCard"), perfLibrary = root.appendingPathComponent("PerformanceLibrary")
try fm.createDirectory(at: perfCard, withIntermediateDirectories: true)
try fm.createDirectory(at: perfLibrary, withIntermediateDirectories: true)
let fixtureSize = 16 * 1024 * 1024
for index in 0..<12 {
    var original = try Data(contentsOf: second)
    original.append(Data(repeating: UInt8(index + 1), count: fixtureSize - original.count))
    try original.write(to: perfCard.appendingPathComponent("new-\(index).JPG"))
    var unrelated = try Data(contentsOf: second)
    unrelated.append(Data(repeating: UInt8(index + 100), count: fixtureSize - unrelated.count))
    try unrelated.write(to: perfLibrary.appendingPathComponent("unrelated-\(index).JPG"))
}
var perfSettings = settings; perfSettings.destination = perfLibrary.path
let scanStart = Date()
var firstResults: TimeInterval = 0
let fastPlan = try Importer.plan(
    source: perfCard, settings: perfSettings, event: "Performance", fallback: nil, helper: helper, cancellation: cancellation,
    progress: { _ in }, discovered: { _ in firstResults = Date().timeIntervalSince(scanStart) })
let scanTime = Date().timeIntervalSince(scanStart)
try check(fastPlan.newCount == 12 && fastPlan.missingCount == 0, "large same-size unrelated files are correctly classified as new with native capture dates")
try check(
    fastPlan.scanReads.hashedBytes == 0 && fastPlan.scanReads.sampledBytes <= 24 * 96 * 1024 && fastPlan.scanReads.headerBytes <= 12 * 256 * 1024,
    "cold preview reads bounded headers and samples instead of full new originals or unrelated candidates")
print(
    String(
        format:
            "Preview of OS-cached synthetic files (not a real-card benchmark): groups shown after %.3f s, complete after %.3f s; %.2f MiB headers, %.2f MiB sampled, %.2f MiB fully hashed for 384 MiB of originals/candidates.",
        firstResults, scanTime, Double(fastPlan.scanReads.headerBytes) / 1_048_576, Double(fastPlan.scanReads.sampledBytes) / 1_048_576, Double(fastPlan.scanReads.hashedBytes) / 1_048_576))
// Make a deliberate sample collision by altering an unsampled byte only.
let collisionSource = perfCard.appendingPathComponent("new-0.JPG")
var collisionBytes = try Data(contentsOf: collisionSource); collisionBytes[128 * 1024] = 250
let collisionTarget = perfLibrary.appendingPathComponent("sample-collision.NEF")
try collisionBytes.write(to: collisionTarget)
let sourceSample = try Importer.fingerprint(collisionSource, cancellation: cancellation).0
let targetSample = try Importer.fingerprint(collisionTarget, cancellation: cancellation).0
try check(sourceSample == targetSample, "adversarial fixture shares samples but differs outside them")
let collisionPreview = try plan(event: "Performance", fallback: fallback, source: perfCard, settings: perfSettings)
try check(collisionPreview.newCount == 12 && collisionPreview.scanReads.hashedBytes == UInt64(2 * fixtureSize), "sample equality triggers full hashing and never falsely skips a different original")
// A same-size edit outside sampled regions after preview must still block copying.
let edited = try FileHandle(forWritingTo: perfCard.appendingPathComponent("new-1.JPG"))
try edited.seek(toOffset: 128 * 1024); try edited.write(contentsOf: Data([251])); try edited.close()
try rejects("unsampled source changes after preview are refused") { _ = try run(fastPlan) }
// Add a real duplicate under an unrelated filename after the collision has been tested.
// The failed import above may have kept its first verified copy; remove that synthetic copy.
let partialVerified = perfLibrary.appendingPathComponent(fastPlan.files.first(where: { $0.source == collisionSource })!.folder!).appendingPathComponent("new-0.JPG")
if fm.fileExists(atPath: partialVerified.path) { try fm.removeItem(at: partialVerified) }
try fm.copyItem(at: collisionSource, to: perfLibrary.appendingPathComponent("renamed-duplicate.data"))
let duplicatePlan = try plan(event: "Performance", fallback: fallback, source: perfCard, settings: perfSettings)
try check(
    duplicatePlan.newCount == 11 && duplicatePlan.files.first(where: { $0.source == collisionSource })?.existing?.lastPathComponent == "renamed-duplicate.data",
    "large renamed duplicates remain detectable after sample filtering")
// MARK: Read-only USB camera snapshots (synthetic transport)
let cameraTemp = root.appendingPathComponent("CameraTemp")
try fm.createDirectory(at: cameraTemp, withIntermediateDirectories: true)
let cameraJPEG = try bytes(first)
let cameraRAW = Data(repeating: 117, count: 4097)
let cameraSidecar = Data("original sidecar".utf8)
let cameraData = ["jpeg": cameraJPEG, "raw": cameraRAW, "sidecar": cameraSidecar, "slot2": cameraJPEG]
let cameraCatalogItems: [String: CameraCatalogItem] = [
    "slot-1": CameraCatalogItem(id: "slot-1", folder: true, name: "Card 1", children: ["dcim-1"]),
    "dcim-1": CameraCatalogItem(id: "dcim-1", folder: true, name: "100NIKON", parent: "slot-1", children: ["raw", "jpeg", "sidecar"]),
    "slot-2": CameraCatalogItem(id: "slot-2", folder: true, name: "Card 2"),
    "dcim-2": CameraCatalogItem(id: "dcim-2", folder: true, name: "100NIKON", parent: "slot-2"),
    "raw": CameraCatalogItem(id: "raw", folder: false, name: "DSC_0001.NEF", size: Int64(cameraRAW.count), parent: "dcim-1"),
    "jpeg": CameraCatalogItem(id: "jpeg", folder: false, name: "DSC_0001.JPG", size: Int64(cameraJPEG.count), parent: "dcim-1"),
    "sidecar": CameraCatalogItem(id: "sidecar", folder: false, name: "DSC_0001.XMP", size: Int64(cameraSidecar.count), parent: "dcim-1"),
    "slot2": CameraCatalogItem(id: "slot2", folder: false, name: "DSC_0001.JPG", size: Int64(cameraJPEG.count), parent: "dcim-2"),
]
let flatCameraCatalog = try CameraCatalog.collect(hierarchy: [], media: ["raw", "jpeg", "slot2"], items: cameraCatalogItems)
try check(
    flatCameraCatalog.count == 3 && flatCameraCatalog[0].folders == flatCameraCatalog[1].folders && flatCameraCatalog[0].folders != flatCameraCatalog[2].folders,
    "Z8-style empty hierarchy still finds media originals and preserves parent folders across slots")
let cameraObjects = try CameraCatalog.collect(hierarchy: ["slot-1"], media: ["raw", "jpeg", "slot2", "raw"], items: cameraCatalogItems)
try check(
    cameraObjects.count == 4 && Set(cameraObjects.map(\.id)).count == 4 && cameraObjects.contains { $0.id == "sidecar" },
    "camera catalog merges hierarchy-only sidecars with flat media originals without duplicates")
let inferredCameraCatalog: [String: CameraCatalogItem] = [
    "root": CameraCatalogItem(id: "root", folder: true, name: "DCIM", children: ["file"]),
    "file": CameraCatalogItem(id: "file", folder: false, name: "DSC_0001.NEF", size: 1),
]
try check(
    try CameraCatalog.collect(hierarchy: ["root"], media: ["file"], items: inferredCameraCatalog).first?.folders.count == 1,
    "hierarchy-only parent relationships are retained when a file omits its parent link")
var cyclicCameraCatalog = cameraCatalogItems
cyclicCameraCatalog["slot-1"]!.parent = "dcim-1"
try rejects("flat camera catalog refuses cyclic parent folders") { _ = try CameraCatalog.collect(hierarchy: [], media: ["raw"], items: cyclicCameraCatalog) }
var incompleteCameraCatalog = cameraCatalogItems
incompleteCameraCatalog.removeValue(forKey: "dcim-1")
try rejects("flat camera catalog refuses missing parent folders") { _ = try CameraCatalog.collect(hierarchy: [], media: ["raw"], items: incompleteCameraCatalog) }
var convertedCameraCatalog = cameraCatalogItems
convertedCameraCatalog["raw"]!.originalName = "DSC_0001.HIF"
try rejects("flat camera catalog refuses converted filenames") { _ = try CameraCatalog.collect(hierarchy: [], media: ["raw"], items: convertedCameraCatalog) }

func cameraRead(_ object: CameraObject, _ offset: Int64, _ length: Int) throws -> Data {
    let data = cameraData[object.id]!
    // Deliberately short successful reads exercise offset advancement.
    return data.subdata(in: Int(offset)..<min(Int(offset) + min(length, 257), data.count))
}
var cameraCopy: CameraSnapshot? = try CameraStaging.prepare(
    cameraObjects, camera: "camera://synthetic/Z8", cancellation: Cancellation(), temporaryRoot: cameraTemp, read: cameraRead, progress: { _ in })
let cameraDirectory = cameraCopy!.directory
try Importer.assertDirectory(cameraDirectory)
let cameraTempAlias = root.appendingPathComponent("CameraTempAlias")
try fm.createSymbolicLink(at: cameraTempAlias, withDestinationURL: cameraTemp)
try rejects("USB staging refuses symlinked temporary roots without weakening source checks") {
    _ = try CameraStaging.prepare(cameraObjects, camera: "camera://synthetic", cancellation: Cancellation(), temporaryRoot: cameraTempAlias, read: cameraRead, progress: { _ in })
}
try check(
    try cameraObjects.allSatisfy { object in
        let path = (object.folders + [object.name]).reduce(cameraDirectory) { $0.appendingPathComponent($1) }
        return try bytes(path) == cameraData[object.id] && Importer.digest(path, cancellation: cancellation).0 == cameraCopy!.hashes[path.path]
    }, "USB snapshot preserves every original byte and verifies transfer hashes after short reads")
let (cameraGroups, cameraOrphans) = Grouping.group(cameraCopy!.hashes.keys.map { URL(fileURLWithPath: $0) })
try check(
    cameraGroups.count == 2 && cameraGroups.contains { $0.members.count == 3 } && cameraOrphans.isEmpty, "USB RAW/JPEG/sidecars group together while repeated names across card slots stay separate")
try check((try fm.attributesOfItem(atPath: cameraDirectory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700, "camera temporary originals are in a private directory")
var usbSettings = Settings(); usbSettings.destination = root.appendingPathComponent("USB-Library").path
try fm.createDirectory(atPath: usbSettings.destination, withIntermediateDirectories: true)
var usbPlan = try plan(event: "", fallback: nil, source: cameraDirectory, settings: usbSettings)
usbPlan.sourceDescription = "camera://synthetic/Z8"; usbPlan.sourceFileDescriptions = cameraCopy!.origins
for i in usbPlan.files.indices { usbPlan.files[i].digest = cameraCopy!.hashes[usbPlan.files[i].source.path] }
let usbResult = try run(usbPlan)
try check(usbResult.copied == 3 && usbResult.skipped == 1, "USB snapshots use content-confirmed duplicates and safe related-file imports")
let usbReport = try JSONSerialization.jsonObject(with: Data(contentsOf: usbResult.receipt)) as! [String: Any]
try check(
    usbReport["source"] as? String == "camera://synthetic/Z8" && (usbReport["entries"] as! [[String: Any]]).allSatisfy { ($0["source"] as? String)?.hasPrefix("camera://synthetic/Z8/") == true },
    "USB reports retain camera provenance instead of disposable temporary paths")
let usbAgain = try run(usbPlan)
try check(usbAgain.copied == 0 && usbAgain.skipped == 4, "USB repeat imports verify existing originals without copying again")
// Even a fresh filesystem preview cannot bless a modified snapshot over its transport hash.
let alteredUSB = usbPlan.files.first { $0.role == .raw }!.source
try Data(repeating: 23, count: cameraRAW.count).write(to: alteredUSB)
var alteredUSBPlan = try plan(event: "", fallback: nil, source: cameraDirectory, settings: usbSettings)
for i in alteredUSBPlan.files.indices { alteredUSBPlan.files[i].digest = cameraCopy!.hashes[alteredUSBPlan.files[i].source.path] }
try rejects("USB transfer hash rejects local snapshot tampering before publication") { _ = try run(alteredUSBPlan) }
cameraCopy = nil
try check(!fm.fileExists(atPath: cameraDirectory.path), "USB temporary originals are removed when their snapshot is released")
func cameraFailure(_ title: String, objects: [CameraObject] = cameraObjects, token: Cancellation = Cancellation(), read: (CameraObject, Int64, Int) throws -> Data) throws {
    try rejects(title) { _ = try CameraStaging.prepare(objects, camera: "camera://synthetic", cancellation: token, temporaryRoot: cameraTemp, read: read, progress: { _ in }) }
    try check(try fm.contentsOfDirectory(atPath: cameraTemp.path).isEmpty, title + " cleans incomplete temporary copies")
}
try cameraFailure("USB premature end-of-file fails closed") { _, _, _ in Data() }
try cameraFailure("USB oversized read fails closed") { _, _, count in Data(repeating: 0, count: count + 1) }
try cameraFailure("USB disconnect fails closed") { object, offset, length in
    if offset > 0 { throw ImportError("Synthetic disconnect") }
    return try cameraRead(object, offset, length)
}
let usbCancel = Cancellation()
try cameraFailure("USB cancellation fails closed", token: usbCancel) { object, offset, length in
    usbCancel.cancel(); return try cameraRead(object, offset, length)
}
for badName in ["../escape.JPG", ".hidden.JPG", "bad:name.JPG", "a\\b.JPG"] {
    let unsafe = CameraObject(id: "unsafe", folders: [], name: badName, size: 1)
    try cameraFailure("USB rejects unsafe camera path " + badName, objects: [unsafe]) { _, _, _ in throw ImportError("Must not read invalid catalog") }
}
let ambiguous = cameraObjects + [CameraObject(id: "collision", folders: cameraObjects.first { $0.id == "jpeg" }!.folders.map { $0.uppercased() }, name: "dsc_0001.jpg", size: 1)]
var invalidCatalogReads = 0
try cameraFailure("USB rejects case-insensitive catalog collisions before transfer", objects: ambiguous) { _, _, _ in
    invalidCatalogReads += 1; return Data([0])
}
try check(invalidCatalogReads == 0, "ambiguous USB catalog never requests original data")

// Full-read verification remains mandatory in the cross-volume overlap path.
let pairMetrics = ReadMetrics()
let pairExpected = try Importer.digest(first, cancellation: Cancellation()).0
let equalPair = try Importer.digestPair(first, first, cancellation: Cancellation(), metrics: pairMetrics)
try check(
    equalPair.0 == pairExpected && equalPair.1 == pairExpected && pairMetrics.hashedBytes == UInt64(try Importer.info(first).st_size) * 2,
    "parallel verification reads and hashes both complete originals")
let pairToken = Cancellation(); pairToken.cancel()
try rejects("parallel verification responds to cancellation") { _ = try Importer.digestPair(first, second, cancellation: pairToken) }
try rejects("parallel verification propagates a missing source") { _ = try Importer.digestPair(root.appendingPathComponent("missing-source"), first, cancellation: Cancellation()) }
try rejects("parallel verification propagates a missing candidate") { _ = try Importer.digestPair(first, root.appendingPathComponent("missing-candidate"), cancellation: Cancellation()) }
let firstCollision = perfLibrary.appendingPathComponent("a-parallel-sample-collision.NEF")
try fm.copyItem(at: collisionTarget, to: firstCollision)
let pairIndex = try LibraryIndex(root: perfLibrary, cancellation: Cancellation())
var collisionHash: String?
let forcedDevice = try Importer.info(collisionTarget).st_dev ^ 1
let parallelCollision = try pairIndex.matches(
    source: collisionSource, size: UInt64(fixtureSize), fingerprint: sourceSample, hash: &collisionHash,
    all: false, cancellation: Cancellation(), sourceDevice: forcedDevice)
try check(
    !parallelCollision.contains(firstCollision) && !parallelCollision.contains(collisionTarget) && parallelCollision.contains { $0.lastPathComponent == "renamed-duplicate.data" },
    "overlapped candidate hashing rejects sample collisions and still finds renamed exact originals")

// MARK: Expiring preview verification hints (synthetic only)
let cacheCard = root.appendingPathComponent("CacheCard"), cacheLibrary = root.appendingPathComponent("CacheLibrary")
try fm.createDirectory(at: cacheCard, withIntermediateDirectories: true)
try fm.createDirectory(at: cacheLibrary, withIntermediateDirectories: true)
let cacheOriginal = cacheCard.appendingPathComponent("CACHE.JPG"), cacheTarget = cacheLibrary.appendingPathComponent("renamed-original.data")
var cacheOriginalBytes = try bytes(first); cacheOriginalBytes.append(Data(repeating: 91, count: 1024 * 1024))
try cacheOriginalBytes.write(to: cacheOriginal); try cacheOriginalBytes.write(to: cacheTarget)
var cacheSettings = Settings(); cacheSettings.destination = cacheLibrary.path
let hintsDirectory = root.appendingPathComponent("VerificationHints")
let epoch = Date(timeIntervalSince1970: 2_000_000_000)
var cacheNow = epoch
func hints(_ directory: URL = hintsDirectory, entries: Int = DuplicateVerificationCache.maximumEntries, bytes: Int = DuplicateVerificationCache.maximumBytes) -> DuplicateVerificationCache {
    DuplicateVerificationCache(directory: directory, clock: { cacheNow }, entryLimit: entries, byteLimit: bytes)
}
func cachedPlan(reuse: Bool = true) throws -> ImportPlan {
    try Importer.plan(
        source: cacheCard, settings: cacheSettings, event: "", fallback: nil, helper: helper,
        cancellation: Cancellation(), verificationCache: hints(), reuseCachedHashes: reuse, progress: { _ in })
}
let coldHints = try cachedPlan()
try check(coldHints.cachedGroups == 0 && coldHints.scanReads.hashedBytes == UInt64(cacheOriginalBytes.count * 2), "cold preview hashes both complete originals before seeding cache")
let warmHints = try cachedPlan()
try check(
    warmHints.cachedGroups == 1 && warmHints.newCount == 0 && warmHints.scanReads.hashedBytes == 0 && warmHints.scanReads.sampledBytes > 0,
    "persisted warm preview checks samples and recognizes renamed copies without full reads")
try check(warmHints.scanReads.total < UInt64(cacheOriginalBytes.count), "warm duplicate scan reads less than one complete original")
let adoptedDirectory = root.appendingPathComponent("AdoptedHints"), keptDirectory = root.appendingPathComponent("KeptHints")
DuplicateVerificationCache.adopt(from: hintsDirectory, into: adoptedDirectory)
try check(hints().count == 2 && hints(adoptedDirectory).count == 2 && fm.fileExists(atPath: hints().file.path), "a renamed install adopts the earlier verification cache and leaves it in place")
hints(keptDirectory).save()
DuplicateVerificationCache.adopt(from: hintsDirectory, into: keptDirectory)
try check(hints(keptDirectory).count == 0, "adopting never replaces an existing verification cache")
let fullHints = try cachedPlan(reuse: false)
try check(fullHints.cachedGroups == 0 && fullHints.scanReads.hashedBytes == UInt64(cacheOriginalBytes.count * 2), "Full Verification bypasses warm hints and refreshes complete hashes")
cacheNow = epoch.addingTimeInterval(29 * 24 * 60 * 60)
try check(try cachedPlan().scanReads.hashedBytes == 0, "verified hashes remain usable for 29 days")
cacheNow = epoch.addingTimeInterval(30 * 24 * 60 * 60)
let expiredHints = try cachedPlan()
try check(expiredHints.cachedGroups == 0 && expiredHints.scanReads.hashedBytes == UInt64(cacheOriginalBytes.count * 2), "30-day expiry forces complete verification even after recent cache hits")
try check(try cachedPlan().scanReads.hashedBytes == 0, "fresh full verification renews the fixed expiry")
cacheNow = epoch
try check(hints().count == 0, "clock rollback discards future-dated verification hints")
let freshHashes = try cachedPlan(reuse: false)
let cacheSignature = try Importer.info(cacheOriginal), cacheSample = try Importer.fingerprint(cacheOriginal, cancellation: Cancellation()).0
let cacheHash = try Importer.digest(cacheOriginal, cancellation: Cancellation()).0
let cacheScope = DuplicateVerificationCache.namespace(root: cacheLibrary)!
let signatureHints = hints(root.appendingPathComponent("IdentityHints"))
func rememberSignature() { signatureHints.record(cacheOriginal, namespace: cacheScope, info: cacheSignature, sample: cacheSample, hash: cacheHash) }
rememberSignature()
try check(signatureHints.hash(for: cacheOriginal, namespace: cacheScope, info: cacheSignature, sample: cacheSample) == cacheHash, "cache matches complete stored file identity and sample")
for field in ["device", "inode", "size", "mtime", "ctime", "birthtime"] {
    rememberSignature(); var changed = cacheSignature
    switch field {
    case "device": changed.st_dev ^= 1
    case "inode": changed.st_ino &+= 1
    case "size": changed.st_size += 1
    case "mtime": changed.st_mtimespec.tv_nsec += 1
    case "ctime": changed.st_ctimespec.tv_nsec += 1
    default: changed.st_birthtimespec.tv_nsec += 1
    }
    try check(signatureHints.hash(for: cacheOriginal, namespace: cacheScope, info: changed, sample: cacheSample) == nil, "changed \(field) invalidates verification hint")
}
rememberSignature()
try check(
    signatureHints.hash(for: cacheOriginal, namespace: cacheScope, info: cacheSignature, sample: String(repeating: "0", count: 64)) == nil, "changed content samples invalidate verification hint")
rememberSignature()
try check(signatureHints.hash(for: cacheOriginal, namespace: "another-destination", info: cacheSignature, sample: cacheSample) == nil, "cache cannot cross destination roots")
try check(signatureHints.hash(for: cacheTarget, namespace: cacheScope, info: cacheSignature, sample: cacheSample) == nil, "cache cannot cross file paths")
rememberSignature(); signatureHints.save()
let hintFileMode = try Importer.info(signatureHints.file).st_mode & 0o777
try check(hintFileMode == 0o600 && (try Importer.info(signatureHints.file.deletingLastPathComponent()).st_mode & 0o777) == 0o700, "verification cache and directory have private permissions")
cacheNow = epoch.addingTimeInterval(DuplicateVerificationCache.lifetime)
let removedExpired = hints(root.appendingPathComponent("IdentityHints")); removedExpired.save()
try check(removedExpired.count == 0 && hints(root.appendingPathComponent("IdentityHints")).count == 0, "loading and saving purges expired entries from disk")
cacheNow = epoch
let smallHints = hints(root.appendingPathComponent("SmallHints"), entries: 3)
for n in 0..<8 {
    cacheNow = epoch.addingTimeInterval(Double(n))
    smallHints.record(cacheCard.appendingPathComponent("\(n).JPG"), namespace: cacheScope, info: cacheSignature, sample: cacheSample, hash: cacheHash)
}
smallHints.save()
try check(smallHints.count <= 3 && hints(root.appendingPathComponent("SmallHints"), entries: 3).count <= 3, "entry-count cap bounds high-volume cache growth")
try check(
    smallHints.hash(for: cacheCard.appendingPathComponent("7.JPG"), namespace: cacheScope, info: cacheSignature, sample: cacheSample) == cacheHash, "count eviction retains recently verified entries")
let byteHints = hints(root.appendingPathComponent("ByteHints"), bytes: 1024)
for n in 0..<10 { byteHints.record(cacheCard.appendingPathComponent("\(n).JPG"), namespace: cacheScope, info: cacheSignature, sample: cacheSample, hash: cacheHash) }
byteHints.save()
try check(try Importer.info(byteHints.file).st_size <= 1024 && byteHints.count < 10, "serialized byte cap independently bounds the cache")
try Data(repeating: 0, count: 1025).write(to: byteHints.file)
try check(hints(root.appendingPathComponent("ByteHints"), bytes: 1024).count == 0, "oversized cache falls back to a cold scan without an unbounded read")
try Data("not JSON".utf8).write(to: signatureHints.file)
try check(hints(root.appendingPathComponent("IdentityHints")).count == 0, "corrupt cache is disposable rather than an import error")
let aliasDirectory = root.appendingPathComponent("CacheDirectoryAlias")
try fm.createSymbolicLink(at: aliasDirectory, withDestinationURL: hintsDirectory)
let aliasHints = hints(aliasDirectory); aliasHints.save()
try check(aliasHints.count == 0, "cache refuses a symlinked working directory")
let protectedFixture = root.appendingPathComponent("DoNotTouch.txt")
try Data("keep these bytes".utf8).write(to: protectedFixture)
let linkHintsDirectory = root.appendingPathComponent("LinkedHints")
try fm.createDirectory(at: linkHintsDirectory, withIntermediateDirectories: true)
try fm.createSymbolicLink(at: linkHintsDirectory.appendingPathComponent("verified-hashes-v1.json"), withDestinationURL: protectedFixture)
let linkHints = hints(linkHintsDirectory); linkHints.save()
try check(linkHints.count == 0 && (try bytes(protectedFixture)) == Data("keep these bytes".utf8), "cache never follows or writes through a linked cache file")

// Every selected file is fully rechecked during import even if preview hints lie.
cacheNow = epoch
_ = try cachedPlan(reuse: false)
let damagedDestination = try FileHandle(forWritingTo: cacheTarget)
try damagedDestination.seek(toOffset: 128 * 1024); try damagedDestination.write(contentsOf: Data([42])); try damagedDestination.close()
let unchangedSamples = try Importer.fingerprint(cacheTarget, cancellation: Cancellation()).0
try check(unchangedSamples == cacheSample && (try Importer.digest(cacheTarget, cancellation: Cancellation()).0) != cacheHash, "cache adversary changes bytes outside sampled regions")
let poisonedHints = hints()
poisonedHints.record(cacheTarget, namespace: cacheScope, info: try Importer.info(cacheTarget), sample: unchangedSamples, hash: cacheHash)
poisonedHints.save()
let guessedMatch = try cachedPlan()
try check(guessedMatch.newCount == 0 && guessedMatch.cachedGroups == 1, "preview labels even an adversarial stale-hash match as cached")
let damagedBytes = try bytes(cacheTarget)
let genuinelyNew = cacheCard.appendingPathComponent("NEW.JPG")
var extraOriginal = cacheOriginalBytes; extraOriginal.append(99); try extraOriginal.write(to: genuinelyNew)
let mixedPreview = try cachedPlan()
try check(mixedPreview.cachedGroups == 1 && mixedPreview.importableNewGroups.count == 1, "mixed preview contains a cached skip and a genuinely new original")
try rejects("cached matches outside Import All New selection cannot authorize completion or ejection") {
    _ = try Importer.run(mixedPreview, selection: mixedPreview.importableNewGroups, cancellation: Cancellation(), reportDirectory: reports, verificationCache: hints(), progress: { _ in })
}
try check(
    (try bytes(cacheTarget)) == damagedBytes && !fm.fileExists(atPath: cacheLibrary.appendingPathComponent("2025/05/18/NEW.JPG").path),
    "stale cached skip aborts before publishing any selected new original")
try fm.removeItem(at: genuinelyNew)
let rebuiltPreview = try cachedPlan(reuse: false)
try check(rebuiltPreview.newCount == 1 && rebuiltPreview.cachedGroups == 0, "Full Verification corrects an incorrect cached destination match")
let strictlyImported = try Importer.run(guessedMatch, cancellation: Cancellation(), reportDirectory: reports, verificationCache: hints(), progress: { _ in })
try check(
    strictlyImported.copied == 1 && strictlyImported.skipped == 0 && (try bytes(cacheTarget)) == damagedBytes,
    "selected-file import independently rejects a cached destination skip and preserves different existing bytes")
try check((try bytes(strictlyImported.outcomes[cacheOriginal.path]!)) == cacheOriginalBytes, "new copy from cached preview still matches source byte-for-byte")
let afterImportHints = try cachedPlan()
try check(afterImportHints.newCount == 0 && afterImportHints.cachedGroups == 1, "verified imports populate reusable preview hints")
try fm.removeItem(at: hintsDirectory)
let recordAfterImport = hints()
let noCachePreview = try cachedPlan(reuse: false)
// Keep only the now-current matching path; remove the damaged synthetic candidate.
try fm.removeItem(at: cacheTarget)
try fm.removeItem(at: hintsDirectory)
let freshImportHints = hints()
let strictRepeat = try Importer.run(noCachePreview, cancellation: Cancellation(), reportDirectory: reports, verificationCache: freshImportHints, progress: { _ in })
try check(strictRepeat.copied == 0 && strictRepeat.skipped == 1 && (try cachedPlan().scanReads.hashedBytes) == 0, "a successful import seeds hashes without needing a separate full preview afterward")
// Metadata changes invalidate a source hint even when the sampled bytes are equal.
let modifiedSource = try FileHandle(forWritingTo: cacheOriginal)
try modifiedSource.seek(toOffset: 128 * 1024); try modifiedSource.write(contentsOf: Data([33])); try modifiedSource.close()
let changedSourcePreview = try cachedPlan()
try check(
    changedSourcePreview.newCount == 1 && changedSourcePreview.scanReads.hashedBytes >= UInt64(cacheOriginalBytes.count), "unsampled source edits with changed attributes force a complete new hash")
let falseSourceHints = hints()
falseSourceHints.record(cacheOriginal, namespace: cacheScope, info: try Importer.info(cacheOriginal), sample: cacheSample, hash: cacheHash)
falseSourceHints.save()
let falseSourcePreview = try cachedPlan()
try check(falseSourcePreview.newCount == 0 && falseSourcePreview.cachedGroups == 1, "adversarial cached source identity is visibly provisional")
try rejects("import rejects stale cached source hashes even when samples agree") {
    _ = try Importer.run(falseSourcePreview, cancellation: Cancellation(), reportDirectory: reports, verificationCache: hints(), progress: { _ in })
}
try check((try bytes(strictlyImported.outcomes[cacheOriginal.path]!)) == cacheOriginalBytes, "rejected stale source hint leaves verified originals untouched")
try fm.removeItem(at: strictlyImported.outcomes[cacheOriginal.path]!)
try check(try cachedPlan().files.first?.existing == nil, "deleting a cached destination cannot hide a missing copy")

// MARK: Design tokens
// The shared table in docs/DESIGN-TOKENS.md is the source of truth; the app's constants must match it.
let tokenDocument = try String(contentsOfFile: "docs/DESIGN-TOKENS.md", encoding: .utf8)
func tokenRows(_ heading: String) -> [[String]] {
    guard let section = tokenDocument.components(separatedBy: "\n## ").first(where: { $0.hasPrefix(heading + "\n") }) else { return [] }
    return section.split(separator: "\n").filter { $0.hasPrefix("| ") }.dropFirst()
        .map { $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) } }
}
try check(tokenDocument.hasPrefix("# SENEX family design tokens v\(DesignTokens.version)\n"), "design tokens follow the shared table's version")
let documentedColors = Dictionary(uniqueKeysWithValues: tokenRows("Colours").map { ($0[0], UInt32($0[1].dropFirst(), radix: 16)) })
try check(documentedColors == DesignTokens.colors.mapValues { Optional($0) }, "colour tokens match the shared table")
let documentedRadii = Dictionary(uniqueKeysWithValues: tokenRows("Corner radii").map { ($0[0], Double($0[1])) })
try check(documentedRadii == DesignTokens.radii.mapValues { Optional($0) }, "corner radii match the shared table")
let documentedType = Dictionary(
    uniqueKeysWithValues: tokenRows("Type roles").map { row in
        (row[0], Double(row[1]).map { DesignTokens.TypeRole(size: $0, semibold: row[2] == "Semibold") })
    })
try check(documentedType == DesignTokens.type.mapValues { Optional($0) }, "type roles match the shared table")

print("\(checks) checks passed. Fixtures removed; no real card or photo library was modified.")
