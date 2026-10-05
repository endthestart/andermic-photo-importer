import Foundation

/// The bundled ExifTool and the Perl runtime that executes it.
/// The app never searches PATH, Homebrew, or the system Perl.
struct MetadataHelper {
    let directory: URL
    var perl: URL { directory.appendingPathComponent("perl/bin/perl") }
    var script: URL { directory.appendingPathComponent("exiftool/exiftool") }
    var licenses: URL { directory.appendingPathComponent("licenses", isDirectory: true) }
    var manifest: URL { directory.appendingPathComponent("manifest.json") }

    init(directory: URL) { self.directory = directory.standardizedFileURL }

    static func bundled(_ bundle: Bundle = .main) -> MetadataHelper? {
        guard let resources = bundle.resourceURL else { return nil }
        let helper = MetadataHelper(directory: resources.appendingPathComponent("MetadataHelper", isDirectory: true))
        return (try? helper.validate()) == nil ? nil : helper
    }

    func validate() throws {
        for (url, executable) in [(perl, true), (script, false)] {
            var value = stat()
            guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG,
                  !executable || FileManager.default.isExecutableFile(atPath: url.path) else {
                throw ImportError("The app's built-in metadata reader is missing or damaged (\(url.lastPathComponent)). Reinstall Andermic Photo Importer.")
            }
        }
    }

    /// A process that runs the bundled script with the bundled interpreter in a clean environment,
    /// so PERL5LIB/PERL5OPT or a user ExifTool configuration cannot change its behavior.
    func process(arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = perl
        process.arguments = [script.path, "-config", ""] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C"]
        process.currentDirectoryURL = directory
        return process
    }

    func version() throws -> String {
        try validate()
        let pipe = Pipe(), process = self.process(arguments: ["-ver"])
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, !text.isEmpty else { throw ImportError("The built-in metadata reader did not start.") }
        return text
    }

    struct Component: Codable { let name: String, version: String, source: String, sha256: String, license: String, modifications: String }
    struct Manifest: Codable { let architecture: String, minimumMacOS: String, components: [Component] }
    func readManifest() -> Manifest? {
        (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
    }
}
