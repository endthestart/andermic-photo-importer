import AppKit
import ImageIO

/// Loads grid thumbnails off the main thread with bounded concurrency and an in-memory cache.
/// Thumbnails are display-only: a file whose preview cannot be rendered is still importable.
final class ThumbnailLoader {
    private let queue = OperationQueue()
    private let cache = NSCache<NSString, NSImage>()
    private var failed = Set<String>()
    private let lock = NSLock()

    init() {
        queue.name = "Andermic thumbnails"
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
        cache.countLimit = 1500
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    var concurrency: Int {
        get { queue.maxConcurrentOperationCount }
        set { queue.maxConcurrentOperationCount = newValue }
    }

    /// The key includes file identity and modification time, so changed content never reuses a stale preview.
    static func key(_ url: URL) -> String {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { return url.path }
        return "\(url.path)|\(value.st_ino)|\(value.st_size)|\(value.st_mtimespec.tv_sec).\(value.st_mtimespec.tv_nsec)"
    }

    func cached(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }
    func hasFailed(_ key: String) -> Bool { lock.lock(); defer { lock.unlock() }; return failed.contains(key) }

    func load(_ url: URL, key: String, completion: @escaping (NSImage?) -> Void) -> Operation {
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let self, let operation, !operation.isCancelled else { return }
            let image = Self.render(url)
            if let image {
                let cost = Int(image.size.width * image.size.height * 4)
                self.cache.setObject(image, forKey: key as NSString, cost: cost)
            } else { self.lock.lock(); self.failed.insert(key); self.lock.unlock() }
            DispatchQueue.main.async { if !operation.isCancelled { completion(image) } }
        }
        queue.addOperation(operation)
        return operation
    }

    func cancelAll() { queue.cancelAllOperations() }

    static func render(_ url: URL, maxPixels: Int = 480) -> NSImage? {
        guard MediaTypes.role(of: url) != .video,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        func thumbnail(always: Bool) -> CGImage? {
            CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailFromImageAlways: always,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary)
        }
        // Prefer an embedded preview; decode the image only when that preview is too small to look sharp.
        var image = thumbnail(always: false)
        if let small = image, max(small.width, small.height) < 280, MediaTypes.role(of: url) == .image { image = thumbnail(always: true) ?? small }
        return image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }
}

struct GridEntry {
    let id: Int
    let name: String
    let thumbnail: URL
    let kinds: String
    let fileCount: Int
    let detail: String
    let status: GroupStatus?
    let missingDate: Bool
    let destination: String?
    var dateOrigin: String? = nil
    var selectable: Bool { status != nil && status != .imported }
}

final class GroupTileView: NSView {
    let imageView = NSImageView()
    let frameView = NSView()
    let check = NSImageView()
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    let kindBadge = Pill()
    let statusBadge = Pill()
    var onToggle: ((NSEvent.ModifierFlags) -> Void)?
    private(set) var entry: GridEntry?
    private(set) var isChecked = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = 6
        frameView.layer?.masksToBounds = true
        frameView.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: 11, weight: .medium); nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: 10); detailLabel.textColor = .secondaryLabelColor; detailLabel.lineBreakMode = .byTruncatingTail
        for view in [frameView, imageView, check, nameLabel, detailLabel, kindBadge, statusBadge] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(frameView); frameView.addSubview(imageView)
        for view in [check, kindBadge, statusBadge, nameLabel, detailLabel] as [NSView] { addSubview(view) }
        NSLayoutConstraint.activate([
            frameView.topAnchor.constraint(equalTo: topAnchor),
            frameView.leadingAnchor.constraint(equalTo: leadingAnchor),
            frameView.trailingAnchor.constraint(equalTo: trailingAnchor),
            frameView.heightAnchor.constraint(equalTo: frameView.widthAnchor, multiplier: 0.75),
            imageView.topAnchor.constraint(equalTo: frameView.topAnchor), imageView.bottomAnchor.constraint(equalTo: frameView.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: frameView.leadingAnchor), imageView.trailingAnchor.constraint(equalTo: frameView.trailingAnchor),
            check.topAnchor.constraint(equalTo: frameView.topAnchor, constant: 6),
            check.trailingAnchor.constraint(equalTo: frameView.trailingAnchor, constant: -6),
            check.widthAnchor.constraint(equalToConstant: 22), check.heightAnchor.constraint(equalToConstant: 22),
            kindBadge.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 6),
            kindBadge.bottomAnchor.constraint(equalTo: frameView.bottomAnchor, constant: -6),
            statusBadge.leadingAnchor.constraint(equalTo: frameView.leadingAnchor, constant: 6),
            statusBadge.topAnchor.constraint(equalTo: frameView.topAnchor, constant: 6),
            statusBadge.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -4),
            nameLabel.topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: 5),
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2), nameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor), detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: GridEntry, checked: Bool) {
        self.entry = entry; isChecked = checked
        nameLabel.stringValue = entry.name
        detailLabel.stringValue = entry.detail
        kindBadge.text = entry.kinds
        let statusText: String?
        switch entry.status {
        case nil: statusText = "Checking…"
        case .imported?: statusText = "Imported"
        case .partial?: statusText = "Partly imported"
        case .sidecarChanged?: statusText = "Sidecar differs"
        case .sourceDuplicate?: statusText = "Duplicate in source"
        case .new?: statusText = entry.missingDate ? "No capture date" : nil
        }
        statusBadge.text = statusText ?? ""
        statusBadge.isHidden = statusText == nil
        statusBadge.tint = entry.missingDate && entry.status != .imported ? .systemRed : (entry.status == .imported ? .systemGreen : .black)
        let dimmed = entry.status == .imported || entry.status == .sourceDuplicate
        imageView.alphaValue = dimmed ? 0.45 : 1
        updateCheck()
        toolTip = ([entry.name + " — " + entry.kinds, entry.detail] + (entry.dateOrigin.map { ["Date from " + $0] } ?? [])
            + (entry.destination.map { ["→ " + $0] } ?? [])).joined(separator: "\n")
        setAccessibilityLabel("\(entry.name), \(entry.kinds), \(entry.detail)\(statusText.map { ", " + $0 } ?? "")")
    }

    func updateCheck() {
        guard let entry else { return }
        check.isHidden = !entry.selectable
        let name = isChecked ? "checkmark.circle.fill" : "circle"
        let configuration = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
            .applying(isChecked ? .init(paletteColors: [.white, .controlAccentColor]) : .init(paletteColors: [.white]))
        check.image = NSImage(systemSymbolName: name, accessibilityDescription: isChecked ? "Selected" : "Not selected")?.withSymbolConfiguration(configuration)
        check.shadow = { let shadow = NSShadow(); shadow.shadowBlurRadius = 2; shadow.shadowColor = .black.withAlphaComponent(0.5); return shadow }()
        frameView.layer?.borderWidth = isChecked ? 3 : 0
        frameView.layer?.borderColor = NSColor.controlAccentColor.cgColor
        setAccessibilityValue(isChecked)
        setAccessibilityEnabled(entry.selectable)
    }

    func setImage(_ image: NSImage?, placeholder: Bool) {
        if let image, !placeholder {
            imageView.image = image; imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.contentTintColor = nil
        } else {
            let isVideo = entry.map { MediaTypes.role(of: $0.thumbnail) == .video } ?? false
            imageView.image = NSImage(systemSymbolName: isVideo ? "video" : "photo", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
            imageView.imageScaling = .scaleNone
            imageView.contentTintColor = .tertiaryLabelColor
        }
    }

    override func mouseDown(with event: NSEvent) { onToggle?(event.modifierFlags) }
    override func accessibilityPerformPress() -> Bool { onToggle?([]); return true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Pill: NSView {
    private let label = NSTextField(labelWithString: "")
    var text: String { get { label.stringValue } set { label.stringValue = newValue; isHidden = newValue.isEmpty } }
    var tint: NSColor = .black { didSet { layer?.backgroundColor = tint.withAlphaComponent(tint == .black ? 0.62 : 0.85).cgColor } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 9.5, weight: .semibold); label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false; addSubview(label)
        NSLayoutConstraint.activate([label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
                                     label.topAnchor.constraint(equalTo: topAnchor, constant: 2), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)])
        tint = .black
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class GroupTileItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("GroupTile")
    let tile = GroupTileView()
    var operation: Operation?
    override func loadView() { view = tile }
    override func prepareForReuse() {
        super.prepareForReuse()
        operation?.cancel(); operation = nil
        tile.imageView.image = nil; tile.onToggle = nil
    }
}

final class SectionHeader: NSView, NSCollectionViewElement {
    static let identifier = NSUserInterfaceItemIdentifier("SectionHeader")
    let title = NSTextField(labelWithString: "")
    let detail = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        detail.font = .systemFont(ofSize: 12); detail.textColor = .secondaryLabelColor
        let row = NSStackView(views: [title, detail]); row.spacing = 8; row.alignment = .firstBaseline
        row.translatesAutoresizingMaskIntoConstraints = false; addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)])
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The grid's own ⌘A selects all new photos (checkmarks), not collection-view items.
final class PhotoCollectionView: NSCollectionView {
    var onSelectAll: (() -> Void)?
    override func selectAll(_ sender: Any?) { onSelectAll?() }
}

/// A scroll view that accepts a dropped folder as the import source.
final class DropScrollView: NSScrollView {
    var onDropFolder: ((URL) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { fatalError() }
    private func folder(_ info: NSDraggingInfo) -> URL? {
        guard let url = (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first else { return nil }
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue ? url : nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { folder(sender) == nil || onDropFolder == nil ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = folder(sender), let onDropFolder else { return false }
        onDropFolder(url); return true
    }
}
