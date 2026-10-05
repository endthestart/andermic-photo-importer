import AppKit

// Diagnostics for packaging checks: confirm the app reads metadata with its own bundled helper.
// Usage: PhotoImport --verify-metadata-helper <photo>
if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-metadata-helper" {
    guard let helper = MetadataHelper.bundled() else { FileHandle.standardError.write(Data("Bundled metadata helper missing.\n".utf8)); exit(1) }
    do {
        let file = URL(fileURLWithPath: CommandLine.arguments[2])
        let dates = try Importer.dates([file], helper: helper, cancellation: Cancellation())
        guard let (day, origin) = dates[file.path] else { throw ImportError("No capture date found in \(file.path).") }
        print("perl=\(helper.perl.path)")
        print("exiftool=\(helper.script.path) version=\(try helper.version())")
        print("date=\(day.text) origin=\(origin)")
        exit(0)
    } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.setActivationPolicy(.accessory)
application.delegate = delegate
application.run()
