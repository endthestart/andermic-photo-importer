import Foundation
import ImageIO
import Darwin

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
    guard condition() else { throw ImportError("FAIL: " + name) }
    checks += 1; print("PASS: " + name)
}
func rejects(_ name: String, _ body: () throws -> Void) throws {
    var rejected = false
    do { try body() } catch { rejected = true }
    try check(rejected, name)
}
let fm = FileManager.default
let testRoot = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
try fm.createDirectory(at: testRoot, withIntermediateDirectories: true)
let root = testRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
try fm.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: root) }
let card = root.appendingPathComponent("Card"), library = root.appendingPathComponent("Library"), reports = root.appendingPathComponent("Reports")
try fm.createDirectory(at: card, withIntermediateDirectories: true)
try fm.createDirectory(at: library, withIntermediateDirectories: true)
let cancellation = Cancellation()
func jpeg(_ name: String, day: String?, color: UInt8) throws -> URL {
    let url = card.appendingPathComponent(name)
    let bytes: [UInt8] = [color, 70, 20, 255, color, 70, 20, 255, color, 70, 20, 255, color, 70, 20, 255]
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let writer = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
    let properties: [CFString: Any] = day.map { [kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: $0]] } ?? [:]
    CGImageDestinationAddImage(writer, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(writer) else { throw ImportError("Fixture generation failed") }
    return url
}
var settings = Settings(); settings.destination = library.path
settings.exiftool = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "/opt/homebrew/bin/exiftool"
let first = try jpeg("DSC_0001.JPG", day: "2025:05:18 23:59:59", color: 200)
let second = try jpeg("DSC_0002.JPG", day: "2025:05:19 00:00:01", color: 100)
let originalHash = try Importer.digest(first, cancellation: cancellation).0
let toolDates = try Importer.dates([first, second], tool: settings.exiftool, cancellation: cancellation)
try check(toolDates[first.path]?.0 == CaptureDay(year: 2025, month: 5, day: 18), "ExifTool fallback reads real embedded capture dates")
let fallback = CaptureDay(year: 2025, month: 5, day: 18)
func plan(event: String = "Soccer Tournament", fallback: CaptureDay? = nil) throws -> ImportPlan {
    try Importer.plan(source: card, settings: settings, event: event, fallback: fallback, cancellation: cancellation, progress: { _ in })
}
func run(_ plan: ImportPlan, token: Cancellation? = nil, progress: ((String) -> Void)? = nil) throws -> ImportResult {
    try Importer.run(plan, cancellation: token ?? cancellation, reportDirectory: reports, progress: progress ?? { _ in })
}
try check(CaptureDay.parse("2024:02:29 00:00:00") != nil && CaptureDay.parse("2025:02:29 00:00:00") == nil, "calendar validation rejects impossible dates")
try check(CaptureDay.parse("2025:05:18 23:59:59-10:00") == fallback, "camera-local day remains unchanged by timezone")
let format = try Importer.folder(template: "{YYYY}/{MM}-{DD} - {event}", event: "Soccer Tournament", date: fallback)
try check(format == "2025/05-18 - Soccer Tournament", "requested folder layout")
try rejects("event cannot escape destination") { _ = try Importer.folder(template: "{event}", event: "../escape", date: fallback) }
try rejects("template cannot escape destination") { _ = try Importer.folder(template: "../{YYYY}", event: "", date: fallback) }
try rejects("unknown template token rejected") { _ = try Importer.folder(template: "{YYYY}/{MONTH}", event: "", date: fallback) }
let preview = try plan()
try check(preview.newCount == 2 && preview.files[0].folder == "2025/05-18 - Soccer Tournament" && preview.files[1].folder == "2025/05-19 - Soccer Tournament", "native capture metadata and multi-day folder preview")
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
try check(repeatPlan.newCount == 0, "existing files detected across different event folders")
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
    _ = try run(finalPlan, progress: { text in
        if !tampered && text.hasPrefix("Final verification:") { try? Data("tampered".utf8).write(to: finalTarget); tampered = true }
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
let fastPlan = try Importer.plan(source: perfCard, settings: perfSettings, event: "Performance", fallback: nil, cancellation: cancellation, progress: { _ in })
let scanTime = Date().timeIntervalSince(scanStart)
try check(fastPlan.newCount == 12 && fastPlan.missingCount == 0, "large same-size unrelated files are correctly classified as new with native capture dates")
try check(fastPlan.scanReads.hashedBytes == 0 && fastPlan.scanReads.sampledBytes <= 24 * 96 * 1024, "cold preview reads bounded samples instead of full new originals or unrelated candidates")
print(String(format: "Cold preview: %.3f seconds; %.2f MiB sampled, %.2f MiB fully hashed for 384 MiB of originals/candidates.", scanTime, Double(fastPlan.scanReads.sampledBytes) / 1048576, Double(fastPlan.scanReads.hashedBytes) / 1048576))
// Make a deliberate sample collision by altering an unsampled byte only.
let collisionSource = perfCard.appendingPathComponent("new-0.JPG")
var collisionBytes = try Data(contentsOf: collisionSource); collisionBytes[128 * 1024] = 250
let collisionTarget = perfLibrary.appendingPathComponent("sample-collision.NEF")
try collisionBytes.write(to: collisionTarget)
let sourceSample = try Importer.fingerprint(collisionSource, cancellation: cancellation).0
let targetSample = try Importer.fingerprint(collisionTarget, cancellation: cancellation).0
try check(sourceSample == targetSample, "adversarial fixture shares samples but differs outside them")
let collisionPlan = try Importer.plan(source: perfCard, settings: perfSettings, event: "Performance", fallback: fallback, cancellation: cancellation, progress: { _ in })
try check(collisionPlan.newCount == 12 && collisionPlan.scanReads.hashedBytes == UInt64(2 * fixtureSize), "sample equality triggers full hashing and never falsely skips a different original")
// A same-size edit outside sampled regions after preview must still block copying.
let edited = try FileHandle(forWritingTo: perfCard.appendingPathComponent("new-1.JPG"))
try edited.seek(toOffset: 128 * 1024); try edited.write(contentsOf: Data([251])); try edited.close()
try rejects("unsampled source changes after preview are refused") { _ = try Importer.run(fastPlan, cancellation: cancellation, reportDirectory: reports, progress: { _ in }) }
// Add a real duplicate under an unrelated filename after the collision has been tested.
// The failed import above may have kept its first verified copy; remove that synthetic copy.
let partialVerified = perfLibrary.appendingPathComponent(fastPlan.files.first(where: { $0.source == collisionSource })!.folder!).appendingPathComponent("new-0.JPG")
if fm.fileExists(atPath: partialVerified.path) { try fm.removeItem(at: partialVerified) }
try fm.copyItem(at: collisionSource, to: perfLibrary.appendingPathComponent("renamed-duplicate.data"))
let duplicatePlan = try Importer.plan(source: perfCard, settings: perfSettings, event: "Performance", fallback: fallback, cancellation: cancellation, progress: { _ in })
try check(duplicatePlan.newCount == 11 && duplicatePlan.files.first(where: { $0.source == collisionSource })?.existing?.lastPathComponent == "renamed-duplicate.data", "large renamed duplicates remain detectable after sample filtering")
print("\(checks) checks passed. Fixtures removed; no real card or photo library was modified.")
