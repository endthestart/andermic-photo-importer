import Foundation

enum CardInsertionBehavior: String, Codable, CaseIterable {
    /// Show the window and scan the new card for a preview. Copying always waits for the user.
    case showAndScan
    /// Only indicate that a card is available; the user opens and scans it.
    case indicate
}

struct ImportPreset: Codable, Equatable {
    var name: String
    var destination: String
    var folderTemplate: String
    var openInEditor: Bool
    var eject: Bool
}

struct Settings: Codable, Equatable {
    static let schema = 2
    static let defaultTemplate = "{YYYY}/{MM}/{DD}"
    static var defaultDestination: String {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory() + "/Pictures"
    }

    var schemaVersion = Settings.schema
    var destination = Settings.defaultDestination
    var folderTemplate = Settings.defaultTemplate
    /// Optional editor handoff. The JSON key keeps its prototype name for compatibility.
    var photoLab = ""
    var openInDxO = false
    var eject = false
    var cardInsertion = CardInsertionBehavior.showAndScan
    var presets: [ImportPreset] = []

    init() {}

    // Decode every field independently so prototype settings files (which lack newer
    // keys, and carry an obsolete ExifTool path) keep the user's destination and template.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Settings()
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        destination = try values.decodeIfPresent(String.self, forKey: .destination) ?? defaults.destination
        folderTemplate = try values.decodeIfPresent(String.self, forKey: .folderTemplate) ?? defaults.folderTemplate
        photoLab = try values.decodeIfPresent(String.self, forKey: .photoLab) ?? ""
        openInDxO = try values.decodeIfPresent(Bool.self, forKey: .openInDxO) ?? false
        eject = try values.decodeIfPresent(Bool.self, forKey: .eject) ?? false
        cardInsertion = (try? values.decodeIfPresent(CardInsertionBehavior.self, forKey: .cardInsertion)) ?? .showAndScan
        presets = (try? values.decodeIfPresent([ImportPreset].self, forKey: .presets)) ?? []
        if destination.isEmpty { destination = defaults.destination }
        if folderTemplate.isEmpty { folderTemplate = defaults.folderTemplate }
    }

    /// `-AndermicSettingsDirectory <path>` isolates settings and reports, for example during GUI testing.
    static var overrideDirectory: URL? {
        UserDefaults.standard.string(forKey: "AndermicSettingsDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
    static var directory: URL {
        overrideDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Andermic Photo Importer", isDirectory: true)
    }
    /// The prototype's directory. Read once for migration; never modified or deleted.
    static var legacyDirectory: URL {
        overrideDirectory?.appendingPathComponent("Photo Import (legacy)", isDirectory: true)
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Photo Import", isDirectory: true)
    }
    static var reportsDirectory: URL { directory.appendingPathComponent("Reports", isDirectory: true) }

    static func load(directory: URL = Settings.directory, legacyDirectory: URL = Settings.legacyDirectory) -> Settings {
        let url = directory.appendingPathComponent("settings.json")
        var value: Settings
        if let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(Settings.self, from: data) { value = decoded }
            else {
                // Keep an unreadable file for inspection rather than silently replacing it.
                let backup = directory.appendingPathComponent("settings-unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: url, to: backup)
                value = Settings()
            }
        } else if let data = try? Data(contentsOf: legacyDirectory.appendingPathComponent("settings.json")),
                  let legacy = try? JSONDecoder().decode(Settings.self, from: data) {
            value = legacy
            value.schemaVersion = schema
            try? value.save(to: directory)
        } else {
            value = Settings()
        }
        value.schemaVersion = schema
        if value.photoLab.isEmpty || !FileManager.default.fileExists(atPath: value.photoLab) {
            value.photoLab = detectPhotoLab() ?? value.photoLab
        }
        return value
    }

    static func detectPhotoLab(applications: URL = URL(fileURLWithPath: "/Applications")) -> String? {
        let apps = (try? FileManager.default.contentsOfDirectory(atPath: applications.path)) ?? []
        return apps.sorted().last(where: { $0.lowercased().contains("photolab") && $0.hasSuffix(".app") })
            .map { applications.appendingPathComponent($0).path }
    }

    func save(to directory: URL = Settings.directory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent("settings.json"), options: .atomic)
    }

    var editorAvailable: Bool { !photoLab.isEmpty && FileManager.default.fileExists(atPath: photoLab) }
    var editorName: String {
        photoLab.isEmpty ? "DxO PhotoLab" : URL(fileURLWithPath: photoLab).deletingPathExtension().lastPathComponent
    }
}
