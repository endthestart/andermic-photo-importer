import Foundation
import ImageIO
import Darwin

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
    let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
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
try check(helper.perl.path.hasPrefix(testRoot.deletingLastPathComponent().path) || helper.perl.path.contains("/build/metadata-helper/"), "tests use the repository-built bundled helper, not an installed ExifTool")
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
try check(preview.newCount == 2 && preview.files[0].folder == "2025/05-18 - Soccer Tournament" && preview.files[1].folder == "2025/05-19 - Soccer Tournament", "native capture metadata and multi-day folder preview")
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
    _ = try run(finalPlan, progress: { update in
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
try check(groupSettings.folderTemplate == "{YYYY}/{MM}/{DD}", "new settings default to year/month/day")
let groupPlan = try plan(event: "", source: groupCard, settings: groupSettings)
try check(groupPlan.groups.count == 4 && groupPlan.files.count == 9 && groupPlan.orphanSidecars.count == 1, "photo-group and physical-file counts are distinct")
let rawMember = groupPlan.files.first { $0.source == pairRAW }!
try check(rawMember.date == CaptureDay(year: 2025, month: 6, day: 1) && rawMember.dateOrigin.hasPrefix("from IMG_0001.JPG"), "an undated RAW inherits its JPEG companion's capture day and records why")
try check(Set(groupPlan.groups.compactMap(\.folder)) == ["2025/06/01", "2025/06/02", "2025/06/03"] && groupPlan.members(groupPlan.groups[0]).allSatisfy { $0.folder == "2025/06/01" }, "related files share one folder; multi-date imports use one folder per day")
let videoGroup = groupPlan.groups.first { $0.directory.lastPathComponent == "101CAMERA" && $0.name == "MVI_0003" }!
try check(videoGroup.date == nil && groupPlan.missingDates(in: [videoGroup.id]) == 2, "an undated group needs an explicit fallback for every member")
try check(groupPlan.newGroups.count == 4, "new photo groups are selected by default")
let reorganized = try groupPlan.organized(template: "{YYYY}-{MM}-{DD} {event}", event: "Trip", fallback: fallback)
try check(reorganized.groups[0].folder == "2025-06-01 Trip" && reorganized.missingCount == 0 && reorganized.scanReads === groupPlan.scanReads, "changing structure, event, or fallback recomputes folders without rereading files")

// MARK: Selection
let firstDay = groupPlan.groups[0].id
let subset = try run(groupPlan, selection: [firstDay])
let firstDayFolder = groupLibrary.appendingPathComponent("2025/06/01")
try check(subset.copied == 4 && Set(try fm.contentsOfDirectory(atPath: firstDayFolder.path)) == ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0001.xmp", "IMG_0001.CR3.dop"], "importing a selected group copies every member with original names")
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
try check(partialResult.copied == 1 && partialResult.skipped == 1 && fm.fileExists(atPath: groupLibrary.appendingPathComponent("2025/07/04/DSC_5000.NEF").path) && !fm.fileExists(atPath: groupLibrary.appendingPathComponent("2025/07/04/DSC_5000.JPG").path), "only the missing member of a partial group is copied")
// A sidecar edited outside the app no longer matches; it is not new photo content.
try Data("<x:xmpmeta rating=1/>".utf8).write(to: folder100.appendingPathComponent("IMG_0001.xmp"))
let sidecarPlan = try plan(event: "", source: groupCard, settings: groupSettings)
let changedSidecar = group(sidecarPlan, "IMG_0001")
try check(changedSidecar.directory.lastPathComponent == "100CAMERA" && changedSidecar.status == .sidecarChanged && !sidecarPlan.newGroups.contains(changedSidecar.id), "a group whose only change is a sidecar is not selected by default")

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
try check(collisionNames.contains { $0.hasPrefix("DSC_7000__") && $0.hasSuffix(".NEF.xmp") } && (try? Data(contentsOf: collisionFolder.appendingPathComponent("DSC_7000.NEF"))) == Data("an unrelated photo from another camera".utf8), "the full-filename sidecar keeps its photo's name and the existing file is untouched")
try check(!collisionResult.notes.isEmpty, "collision renames are reported")
let collisionRepeat = try plan(event: "", source: collisionCard, settings: groupSettings)
try check(collisionRepeat.groups[0].status == .imported, "suffixed groups, including their sidecars, are recognized on rescan")
_ = collidingJPEG

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
try check(try Importer.files(in: interruptLibrary, allowed: nil, cancellation: cancellation).0.count == 2 && (try fm.subpathsOfDirectory(atPath: interruptLibrary.path)).allSatisfy { !$0.hasSuffix(".partial") }, "cancellation keeps completed copies and removes the in-progress staging file")
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
try check(twinPlan.groups.contains { $0.status == .sourceDuplicate } && twinPlan.missingDates(in: Set(twinPlan.groups.map(\.id))) == 2, "undated duplicates within a source still require a fallback before import")
try rejects("an undated duplicate within the source is refused before any copy") { _ = try run(twinPlan) }

// MARK: Settings migration
let settingsRoot = root.appendingPathComponent("Settings"), legacyRoot = root.appendingPathComponent("LegacySettings")
try fm.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
let legacyJSON = #"{"destination":"/Volumes/Photography/Photo Container","eject":true,"exiftool":"/opt/homebrew/bin/exiftool","folderTemplate":"{YYYY}/{MM}-{DD} - {event}","openInDxO":true,"photoLab":"/Applications/DXOPhotoLab10.app"}"#
try Data(legacyJSON.utf8).write(to: legacyRoot.appendingPathComponent("settings.json"))
let migrated = Settings.load(directory: settingsRoot, legacyDirectory: legacyRoot)
try check(migrated.destination == "/Volumes/Photography/Photo Container" && migrated.folderTemplate == "{YYYY}/{MM}-{DD} - {event}" && migrated.eject && migrated.openInDxO, "prototype settings keep the configured destination, template, and completion options")
try check(migrated.cardInsertion == .showAndScan && migrated.presets.isEmpty && migrated.schemaVersion == Settings.schema, "fields missing from prototype settings use new defaults")
try check(fm.fileExists(atPath: settingsRoot.appendingPathComponent("settings.json").path) && (try Data(contentsOf: legacyRoot.appendingPathComponent("settings.json"))) == Data(legacyJSON.utf8), "migration writes the new location and leaves the prototype file untouched")
let fresh = Settings.load(directory: root.appendingPathComponent("FreshSettings"), legacyDirectory: root.appendingPathComponent("NoLegacy"))
try check(fresh.destination == fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].path && fresh.folderTemplate == "{YYYY}/{MM}/{DD}", "new users default to Pictures and year/month/day")
var customized = migrated
customized.cardInsertion = .indicate
customized.presets = [ImportPreset(name: "Trips", destination: library.path, folderTemplate: "{YYYY}/{event}", openInEditor: false, eject: true)]
try customized.save(to: settingsRoot)
let reloaded = Settings.load(directory: settingsRoot, legacyDirectory: legacyRoot)
try check(reloaded.cardInsertion == .indicate && reloaded.presets == customized.presets && reloaded.destination == customized.destination, "card behavior and saved presets persist")
try Data("{not json".utf8).write(to: settingsRoot.appendingPathComponent("settings.json"))
let recoveredSettings = Settings.load(directory: settingsRoot, legacyDirectory: legacyRoot)
try check(recoveredSettings.folderTemplate == Settings.defaultTemplate && (try fm.contentsOfDirectory(atPath: settingsRoot.path)).contains { $0.hasPrefix("settings-unreadable-") }, "an unreadable settings file is preserved before defaults are used")

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
let fastPlan = try Importer.plan(source: perfCard, settings: perfSettings, event: "Performance", fallback: nil, helper: helper, cancellation: cancellation,
                                 progress: { _ in }, discovered: { _ in firstResults = Date().timeIntervalSince(scanStart) })
let scanTime = Date().timeIntervalSince(scanStart)
try check(fastPlan.newCount == 12 && fastPlan.missingCount == 0, "large same-size unrelated files are correctly classified as new with native capture dates")
try check(fastPlan.scanReads.hashedBytes == 0 && fastPlan.scanReads.sampledBytes <= 24 * 96 * 1024 && fastPlan.scanReads.headerBytes <= 12 * 256 * 1024, "cold preview reads bounded headers and samples instead of full new originals or unrelated candidates")
print(String(format: "Preview of OS-cached synthetic files (not a real-card benchmark): groups shown after %.3f s, complete after %.3f s; %.2f MiB headers, %.2f MiB sampled, %.2f MiB fully hashed for 384 MiB of originals/candidates.",
             firstResults, scanTime, Double(fastPlan.scanReads.headerBytes) / 1048576, Double(fastPlan.scanReads.sampledBytes) / 1048576, Double(fastPlan.scanReads.hashedBytes) / 1048576))
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
try check(duplicatePlan.newCount == 11 && duplicatePlan.files.first(where: { $0.source == collisionSource })?.existing?.lastPathComponent == "renamed-duplicate.data", "large renamed duplicates remain detectable after sample filtering")
print("\(checks) checks passed. Fixtures removed; no real card or photo library was modified.")
