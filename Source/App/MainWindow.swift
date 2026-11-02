import AppKit

enum WorkState { case idle, scanning, importing }

enum TypeFilter: Int, CaseIterable {
    case all, pairs, raw, jpeg, heif, video, other
    var title: String { ["All Types", "RAW + JPEG Pairs", "RAW", "JPEG", "HEIF", "Videos", "Other Images"][rawValue] }
    func matches(_ urls: [URL]) -> Bool {
        let roles = Set(urls.compactMap(MediaTypes.role(of:)))
        let extensions = Set(urls.map { $0.pathExtension.lowercased() })
        switch self {
        case .all: return true
        case .pairs: return roles.contains(.raw) && roles.contains(.image)
        case .raw: return roles.contains(.raw)
        case .jpeg: return !extensions.isDisjoint(with: ["jpg", "jpeg", "jpe"])
        case .heif: return !extensions.isDisjoint(with: ["heic", "heif", "hif"])
        case .video: return roles.contains(.video)
        case .other: return !extensions.isDisjoint(with: ["tif", "tiff", "png", "avif", "webp"])
        }
    }
}

struct FolderStructure {
    let title: String, template: String
    static let all = [
        FolderStructure(title: "Year / Month / Day", template: "{YYYY}/{MM}/{DD}"),
        FolderStructure(title: "Year / Year-Month-Day", template: "{YYYY}/{YYYY}-{MM}-{DD}"),
        FolderStructure(title: "Year / Month-Day - Event", template: "{YYYY}/{MM}-{DD} - {event}"),
        FolderStructure(title: "Year / Event", template: "{YYYY}/{event}"),
        FolderStructure(title: "Event", template: "{event}"),
    ]
}

final class MainWindowController: NSWindowController, NSWindowDelegate, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout,
    NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSToolbarDelegate
{
    var settings: Settings
    let helper: MetadataHelper?
    let thumbnails = ThumbnailLoader()
    var verificationCacheDirectory: URL {
        if let override = Settings.overrideDirectory { return override.appendingPathComponent("VerificationCache", isDirectory: true) }
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Corvus/DuplicateVerification", isDirectory: true)
    }
    var notices: NoticesWindow?

    // Source and scan state
    var cards: [URL] = []
    weak var cameraMonitor: CameraMonitor?
    var cameras: [CameraImportSource] = []
    var cameraSnapshot: CameraSnapshot?
    var newlyAvailable = Set<URL>()
    var source: URL?
    var plan: ImportPlan?
    var organizeError: String?
    var preliminary: [SourceGroup]?
    var selection = Set<Int>()
    var anchor: Int?
    var state = WorkState.idle
    var scanToken: Cancellation?, importToken: Cancellation?
    var scanGeneration = 0
    var scanStarted = Date()
    var quitAfterWork = false
    let launched = Date()
    var onStateChange: (() -> Void)?

    // Display
    var sections: [(title: String, detail: String, entries: [GridEntry])] = []
    var dateFilter: CaptureDay?? = nil  // nil = all; .some(nil) = no capture date
    var dateOptions: [CaptureDay?] = []  // popup items after "All Dates"
    var typeFilter = TypeFilter.all
    var tileWidth: CGFloat = 170

    // Views
    let sidebar = NSTableView()
    let titleLabel = NSTextField(labelWithString: "No source selected")
    let countsLabel = NSTextField(labelWithString: "")
    let datePopup = NSPopUpButton(), typePopup = NSPopUpButton()
    let showImported = NSButton(checkboxWithTitle: "Show Imported", target: nil, action: nil)
    let sizeSlider = NSSlider(value: 170, minValue: 110, maxValue: 300, target: nil, action: nil)
    let collection = PhotoCollectionView()
    let gridScroll = DropScrollView()
    let emptyState = NSTextField(wrappingLabelWithString: "")
    let progressBar = PillProgress()
    let statusLabel = NSTextField(labelWithString: "")
    let selectionLabel = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "Stop", target: nil, action: nil)
    let selectAllButton = NSButton(title: "Select All", target: nil, action: nil)
    let selectAllNewButton = NSButton(title: "Select All New", target: nil, action: nil)
    let deselectAllButton = NSButton(title: "Deselect All", target: nil, action: nil)
    let importAllButton = NSButton(title: "Import All New", target: nil, action: nil)
    let importSelectedButton = NSButton(title: "Import Selected", target: nil, action: nil)
    // Inspector
    let presetPopup = NSPopUpButton()
    let destinationPath = NSTextField(labelWithString: "")
    let destinationButton = NSButton(title: "Choose…", target: nil, action: nil)
    let structurePopup = NSPopUpButton()
    let templateField = NSTextField(string: "")
    let eventField = NSTextField(string: "")
    let previewLabel = NSTextField(wrappingLabelWithString: "")
    let fallbackBox = NSStackView()
    let fallbackCheck = NSButton(checkboxWithTitle: "Use this date for photos without one", target: nil, action: nil)
    let fallbackPicker = NSDatePicker()
    let openEditor = NSButton(checkboxWithTitle: "Open new folders in DxO PhotoLab", target: nil, action: nil)
    let editorNote = NSTextField(wrappingLabelWithString: "")
    let ejectCheck = NSButton(checkboxWithTitle: "Eject card after verified import", target: nil, action: nil)
    let advancedToggle = NSButton(title: "", target: nil, action: nil)
    let advancedBox = NSStackView()
    let cardBehaviorPopup = NSPopUpButton()
    let otherCardPopup = NSPopUpButton()
    let backgroundLaunch = NSButton(checkboxWithTitle: "Start in the menu bar without a window", target: nil, action: nil)
    let editorPath = NSTextField(labelWithString: "")
    var inspectorItem: NSSplitViewItem!
    var sidebarItem: NSSplitViewItem!

    init(settings: Settings, helper: MetadataHelper?) {
        self.settings = settings; self.helper = helper
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Corvus"
        window.backgroundColor = Theme.chrome
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1040, height: 620)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        super.init(window: window)
        window.delegate = self
        build()
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        loadInspector()
        refresh()
        let cacheDirectory = verificationCacheDirectory
        let earlierCaches =
            Settings.overrideDirectory == nil
            ? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Andermic Photo Importer", isDirectory: true) : nil
        if let earlierCaches { DuplicateVerificationCache.adopt(from: earlierCaches.appendingPathComponent("DuplicateVerification", isDirectory: true), into: cacheDirectory) }
        DispatchQueue.global(qos: .utility).async {
            DuplicateVerificationCache(directory: cacheDirectory).save()
            CameraStaging.removeAbandoned()
            if let earlierCaches { CameraStaging.removeAbandoned(in: earlierCaches.appendingPathComponent("CameraTransfers", isDirectory: true), prefix: "andermic-camera-") }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        (NSApp.delegate as? AppDelegate)?.presentWindow()
        super.showWindow(sender)
        window?.deminiaturize(nil)
        window?.makeKeyAndOrderFront(sender)
        // Activation-policy changes settle on the next run-loop turn.
        DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: Layout

    func build() {
        let split = NSSplitViewController()
        split.splitView.autosaveName = "MainSplit"
        sidebarItem = NSSplitViewItem(sidebarWithViewController: viewController(buildSidebar()))
        sidebarItem.minimumThickness = 210; sidebarItem.maximumThickness = 280
        let center = NSSplitViewItem(viewController: viewController(buildCenter()))
        center.minimumThickness = 520
        inspectorItem = NSSplitViewItem(viewController: viewController(buildInspector()))
        inspectorItem.minimumThickness = 290; inspectorItem.maximumThickness = 380
        inspectorItem.canCollapse = true
        split.addSplitViewItem(sidebarItem); split.addSplitViewItem(center); split.addSplitViewItem(inspectorItem)
        window!.contentViewController = split
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window!.toolbar = toolbar
    }
    func viewController(_ view: NSView) -> NSViewController { let controller = NSViewController(); controller.view = view; return controller }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, .init("rescan"), .init("inspector")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: identifier)
        switch identifier.rawValue {
        case "rescan":
            item.label = "Scan Again"; item.toolTip = "Scan the source again (⌘R)"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Scan Again")
            item.target = self; item.action = #selector(rescan)
        case "inspector":
            item.label = "Import Options"; item.toolTip = "Show or hide import options"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Import Options")
            item.target = self; item.action = #selector(toggleInspector)
        default: return nil
        }
        item.isBordered = true
        return item
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }
