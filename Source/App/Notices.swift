import AppKit

/// Shows the bundled components, their pinned sources, and complete license texts.
final class NoticesWindow: NSWindowController {
    convenience init(helper: MetadataHelper?) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Third-Party Notices"
        window.minSize = NSSize(width: 480, height: 360)
        window.setFrameAutosaveName("ThirdPartyNotices")
        self.init(window: window)
        let scroll = NSTextView.scrollableTextView()
        let text = scroll.documentView as! NSTextView
        text.isEditable = false; text.isSelectable = true
        text.textContainerInset = NSSize(width: 18, height: 18)
        text.textStorage?.setAttributedString(Self.content(helper))
        text.setAccessibilityLabel("Third-party notices and licenses")
        window.contentView = scroll
        window.center()
    }

    static func content(_ helper: MetadataHelper?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func add(_ text: String, _ font: NSFont, _ color: NSColor = .labelColor) {
            result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
        }
        add("Third-Party Notices\n\n", .systemFont(ofSize: 20, weight: .semibold))
        add("Andermic Photo Importer includes a built-in metadata reader so capture dates can be read without installing anything else. "
            + "These components are distributed unmodified from the pinned upstream sources below, under their own licenses.\n\n", .systemFont(ofSize: 13))
        guard let helper, let manifest = helper.readManifest() else {
            add("The built-in metadata reader is missing from this copy of the app.\n", .systemFont(ofSize: 13), .systemRed)
            return result
        }
        for component in manifest.components {
            add("\(component.name) \(component.version)\n", .systemFont(ofSize: 15, weight: .semibold))
            add("License: \(component.license)\nSource: \(component.source)\nSHA-256: \(component.sha256)\nChanges: \(component.modifications)\n\n",
                .systemFont(ofSize: 12), .secondaryLabelColor)
        }
        add("Built for \(manifest.architecture), macOS \(manifest.minimumMacOS) or later. ExifTool © Phil Harvey. Perl © Larry Wall and others.\n\n", .systemFont(ofSize: 12), .secondaryLabelColor)
        let files = ((try? FileManager.default.contentsOfDirectory(at: helper.licenses, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in files {
            add("\(file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "-", with: " "))\n", .systemFont(ofSize: 15, weight: .semibold))
            add(((try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? "") + "\n\n", .monospacedSystemFont(ofSize: 11, weight: .regular))
        }
        return result
    }
}
