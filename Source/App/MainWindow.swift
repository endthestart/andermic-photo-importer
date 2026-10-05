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
                                  NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSToolbarDelegate {
    var settings: Settings
    let helper: MetadataHelper?
    let thumbnails = ThumbnailLoader()
    var notices: NoticesWindow?

    // Source and scan state
    var cards: [URL] = []
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
    var dateFilter: CaptureDay?? = nil   // nil = all; .some(nil) = no capture date
    var typeFilter = TypeFilter.all
    var tileWidth: CGFloat = 170

    // Views
    let sidebar = NSTableView()
    let titleLabel = NSTextField(labelWithString: "No source selected")
    let countsLabel = NSTextField(labelWithString: "")
    let datePopup = NSPopUpButton(), typePopup = NSPopUpButton()
    let showImported = NSButton(checkboxWithTitle: "Show Imported", target: nil, action: nil)
    let sizeSlider = NSSlider(value: 170, minValue: 110, maxValue: 300, target: nil, action: nil)
    let collection = NSCollectionView()
    let gridScroll = DropScrollView()
    let emptyState = NSTextField(wrappingLabelWithString: "")
    let progressBar = NSProgressIndicator()
    let statusLabel = NSTextField(labelWithString: "")
    let selectionLabel = NSTextField(labelWithString: "")
    let cancelButton = NSButton(title: "Stop", target: nil, action: nil)
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
    let editorPath = NSTextField(labelWithString: "")
    var inspectorItem: NSSplitViewItem!
    var sidebarItem: NSSplitViewItem!

    init(settings: Settings, helper: MetadataHelper?) {
        self.settings = settings; self.helper = helper
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1320, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Andermic Photo Importer"
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
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    func build() {
        let split = NSSplitViewController()
        split.splitView.autosaveName = "MainSplit"
        sidebarItem = NSSplitViewItem(sidebarWithViewController: viewController(buildSidebar()))
        sidebarItem.minimumThickness = 190; sidebarItem.maximumThickness = 280
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

    func buildSidebar() -> NSView {
        let column = NSTableColumn(identifier: .init("source")); column.title = ""
        sidebar.addTableColumn(column); sidebar.headerView = nil
        sidebar.style = .sourceList; sidebar.rowHeight = 28
        sidebar.dataSource = self; sidebar.delegate = self
        sidebar.target = self; sidebar.action = #selector(sidebarClicked)
        sidebar.setAccessibilityLabel("Import sources")
        let scroll = NSScrollView(); scroll.documentView = sidebar; scroll.drawsBackground = false; scroll.hasVerticalScroller = true
        let choose = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseSource))
        choose.image = NSImage(systemSymbolName: "folder.badge.plus", accessibilityDescription: nil); choose.imagePosition = .imageLeading
        choose.bezelStyle = .rounded; choose.controlSize = .regular
        let hint = small("Insert a camera card, choose a folder, or drop a folder on the grid.")
        let footer = NSStackView(views: [choose, hint]); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 8
        let view = NSView()
        for item in [scroll, footer] as [NSView] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14),
            hint.widthAnchor.constraint(equalTo: footer.widthAnchor),
        ])
        return view
    }

    func buildCenter() -> NSView {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold); titleLabel.lineBreakMode = .byTruncatingMiddle
        countsLabel.font = .systemFont(ofSize: 12); countsLabel.textColor = .secondaryLabelColor
        countsLabel.lineBreakMode = .byTruncatingTail
        datePopup.target = self; datePopup.action = #selector(filtersChanged); datePopup.controlSize = .small
        datePopup.setAccessibilityLabel("Filter by capture date")
        typePopup.addItems(withTitles: TypeFilter.allCases.map(\.title)); typePopup.target = self; typePopup.action = #selector(filtersChanged)
        typePopup.controlSize = .small; typePopup.setAccessibilityLabel("Filter by file type")
        showImported.state = .on; showImported.target = self; showImported.action = #selector(filtersChanged); showImported.controlSize = .small
        sizeSlider.target = self; sizeSlider.action = #selector(resizeTiles); sizeSlider.controlSize = .small
        sizeSlider.setAccessibilityLabel("Thumbnail size")
        sizeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let smallIcon = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!)
        let largeIcon = NSImageView(image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!.withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!)
        for icon in [smallIcon, largeIcon] { icon.contentTintColor = .secondaryLabelColor }
        let titles = NSStackView(views: [titleLabel, countsLabel]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
        let filters = NSStackView(views: [datePopup, typePopup, showImported, NSView(), smallIcon, sizeSlider, largeIcon])
        filters.spacing = 10; filters.alignment = .centerY
        let header = NSStackView(views: [titles, filters]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 10
        filters.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 14; layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 6, left: 20, bottom: 22, right: 20)
        layout.headerReferenceSize = NSSize(width: 0, height: 34)
        collection.collectionViewLayout = layout
        collection.dataSource = self; collection.delegate = self
        collection.isSelectable = false
        collection.backgroundColors = [.clear]
        collection.register(GroupTileItem.self, forItemWithIdentifier: GroupTileItem.identifier)
        collection.register(SectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: SectionHeader.identifier)
        collection.setAccessibilityLabel("Photos to import")
        gridScroll.documentView = collection; gridScroll.hasVerticalScroller = true; gridScroll.drawsBackground = false
        gridScroll.onDropFolder = { [weak self] url in self?.setSource(url, scan: true) }
        emptyState.alignment = .center; emptyState.textColor = .secondaryLabelColor; emptyState.font = .systemFont(ofSize: 14)

        progressBar.style = .bar; progressBar.isIndeterminate = true; progressBar.isDisplayedWhenStopped = false
        progressBar.controlSize = .small; progressBar.minValue = 0; progressBar.maxValue = 1
        progressBar.widthAnchor.constraint(equalToConstant: 140).isActive = true
        statusLabel.font = .systemFont(ofSize: 12); statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectionLabel.font = .systemFont(ofSize: 12, weight: .medium); selectionLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.target = self; cancelButton.action = #selector(cancelWork); cancelButton.keyEquivalent = "\u{1b}"
        importAllButton.target = self; importAllButton.action = #selector(importAllNew); importAllButton.bezelStyle = .rounded
        importSelectedButton.target = self; importSelectedButton.action = #selector(importSelected); importSelectedButton.bezelStyle = .rounded
        importSelectedButton.keyEquivalent = "\r"
        let statusStack = NSStackView(views: [selectionLabel, statusLabel]); statusStack.orientation = .vertical; statusStack.alignment = .leading; statusStack.spacing = 1
        statusStack.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [progressBar, statusStack, cancelButton, importAllButton, importSelectedButton])
        footer.spacing = 10; footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 12, right: 20)

        let view = NSView()
        let topRule = NSBox(), bottomRule = NSBox(); topRule.boxType = .separator; bottomRule.boxType = .separator
        for item in [header, topRule, gridScroll, emptyState, bottomRule, footer] as [NSView] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            filters.widthAnchor.constraint(equalTo: header.widthAnchor),
            topRule.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            topRule.leadingAnchor.constraint(equalTo: view.leadingAnchor), topRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridScroll.topAnchor.constraint(equalTo: topRule.bottomAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), gridScroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            gridScroll.bottomAnchor.constraint(equalTo: bottomRule.topAnchor),
            emptyState.centerXAnchor.constraint(equalTo: gridScroll.centerXAnchor), emptyState.centerYAnchor.constraint(equalTo: gridScroll.centerYAnchor),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            bottomRule.leadingAnchor.constraint(equalTo: view.leadingAnchor), bottomRule.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomRule.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor), footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        return view
    }

    func buildInspector() -> NSView {
        presetPopup.target = self; presetPopup.action = #selector(presetChosen); presetPopup.setAccessibilityLabel("Import preset")
        destinationPath.lineBreakMode = .byTruncatingHead; destinationPath.font = .systemFont(ofSize: 12)
        destinationPath.setAccessibilityLabel("Destination folder")
        destinationButton.target = self; destinationButton.action = #selector(chooseDestination)
        structurePopup.addItems(withTitles: FolderStructure.all.map(\.title) + ["Custom"])
        structurePopup.target = self; structurePopup.action = #selector(structureChosen); structurePopup.setAccessibilityLabel("Folder structure")
        templateField.font = .monospacedSystemFont(ofSize: 12, weight: .regular); templateField.delegate = self
        templateField.setAccessibilityLabel("Folder template")
        eventField.placeholderString = "For example, Lisbon Trip"; eventField.delegate = self; eventField.setAccessibilityLabel("Event name")
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); previewLabel.textColor = .secondaryLabelColor
        previewLabel.setAccessibilityLabel("Destination preview")
        fallbackPicker.datePickerStyle = .textFieldAndStepper; fallbackPicker.datePickerElements = [.yearMonthDay]; fallbackPicker.dateValue = Date()
        fallbackPicker.target = self; fallbackPicker.action = #selector(organizationChanged)
        fallbackCheck.target = self; fallbackCheck.action = #selector(organizationChanged)
        fallbackBox.orientation = .vertical; fallbackBox.alignment = .leading; fallbackBox.spacing = 6
        for view in [section("MISSING CAPTURE DATES"), small("Some photos have no capture date. Nothing is guessed: choose a date for them, or leave them unselected."), fallbackCheck, fallbackPicker] {
            fallbackBox.addArrangedSubview(view)
        }
        openEditor.target = self; openEditor.action = #selector(completionChanged)
        ejectCheck.target = self; ejectCheck.action = #selector(completionChanged)
        editorNote.font = .systemFont(ofSize: 11); editorNote.textColor = .secondaryLabelColor
        advancedToggle.bezelStyle = .disclosure; advancedToggle.setButtonType(.pushOnPushOff); advancedToggle.state = .off
        advancedToggle.target = self; advancedToggle.action = #selector(toggleAdvanced); advancedToggle.setAccessibilityLabel("Show advanced options")
        let advancedTitle = NSButton(title: "Advanced", target: self, action: #selector(toggleAdvancedFromTitle)); advancedTitle.isBordered = false
        advancedTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let advancedRow = NSStackView(views: [advancedToggle, advancedTitle]); advancedRow.spacing = 2
        cardBehaviorPopup.addItems(withTitles: ["Show window and scan the card", "Only show that a card is available"])
        cardBehaviorPopup.target = self; cardBehaviorPopup.action = #selector(cardBehaviorChanged)
        cardBehaviorPopup.setAccessibilityLabel("When a card is inserted")
        editorPath.font = .systemFont(ofSize: 11); editorPath.textColor = .secondaryLabelColor; editorPath.lineBreakMode = .byTruncatingMiddle
        let chooseEditor = NSButton(title: "Choose Editor…", target: self, action: #selector(chooseEditor))
        let reportsButton = NSButton(title: "Show Import Reports", target: self, action: #selector(showReports))
        let noticesButton = NSButton(title: "Third-Party Notices…", target: NSApp.delegate, action: #selector(AppDelegate.showNotices))
        advancedBox.orientation = .vertical; advancedBox.alignment = .leading; advancedBox.spacing = 8
        for view in [label("When a card is inserted"), cardBehaviorPopup,
                     small("Scanning only previews. Copying always waits for an import button, and an import in progress is never interrupted."),
                     label("Editor handoff"), editorPath, chooseEditor,
                     label("Folder template tokens"),
                     small("{YYYY} year · {YY} short year · {MM} month · {DD} day · {event} event name. Use / between folder levels. Each photo uses its own camera-recorded capture day."),
                     reportsButton, noticesButton] {
            advancedBox.addArrangedSubview(view)
        }
        advancedBox.isHidden = true

        let folderIcon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!); folderIcon.contentTintColor = .controlAccentColor
        let destinationRow = NSStackView(views: [folderIcon, destinationPath, destinationButton]); destinationRow.spacing = 6
        destinationPath.setContentHuggingPriority(.defaultLow, for: .horizontal)
        destinationPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 20, right: 16)
        let views: [NSView] = [
            heading("Import Options"),
            section("PRESET"), presetPopup,
            divider(),
            section("DESTINATION"), destinationRow,
            section("FOLDER STRUCTURE"), structurePopup, templateField,
            section("EVENT NAME (OPTIONAL)"), eventField,
            small("Only used by structures that include {event}. Photos from several days go into each day's folder."),
            section("RESULTING FOLDERS"), previewLabel,
            fallbackBox,
            divider(),
            section("AFTER IMPORT"), openEditor, editorNote, ejectCheck,
            divider(),
            advancedRow, advancedBox,
        ]
        for view in views { content.addArrangedSubview(view) }
        for view in views where !(view is NSStackView && view === advancedRow) {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        }
        for view in advancedBox.arrangedSubviews { view.widthAnchor.constraint(equalTo: advancedBox.widthAnchor).isActive = true }
        for view in fallbackBox.arrangedSubviews where view is NSTextField { view.widthAnchor.constraint(equalTo: fallbackBox.widthAnchor).isActive = true }
        content.setCustomSpacing(16, after: presetPopup)
        let document = FlippedView(); document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false; document.addSubview(content)
        let scroll = NSScrollView(); scroll.documentView = document; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let view = NSView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor), content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        return view
    }

    func heading(_ text: String) -> NSTextField { let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 15, weight: .semibold); return field }
    func section(_ text: String) -> NSTextField { let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 10, weight: .semibold); field.textColor = .secondaryLabelColor; return field }
    func label(_ text: String) -> NSTextField { let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 12, weight: .medium); return field }
    func small(_ text: String) -> NSTextField { let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor; return field }
    func divider() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }

    // MARK: Settings

    func loadInspector() {
        destinationPath.stringValue = (settings.destination as NSString).abbreviatingWithTildeInPath
        destinationPath.toolTip = settings.destination
        templateField.stringValue = settings.folderTemplate
        structurePopup.selectItem(at: FolderStructure.all.firstIndex { $0.template == settings.folderTemplate } ?? FolderStructure.all.count)
        openEditor.state = settings.openInDxO ? .on : .off
        ejectCheck.state = settings.eject ? .on : .off
        cardBehaviorPopup.selectItem(at: settings.cardInsertion == .showAndScan ? 0 : 1)
        rebuildPresetMenu()
    }

    func persist() { try? settings.save() }

    func rebuildPresetMenu() {
        presetPopup.removeAllItems()
        let current = settings.presets.firstIndex { $0.destination == settings.destination && $0.folderTemplate == settings.folderTemplate
            && $0.openInEditor == settings.openInDxO && $0.eject == settings.eject }
        presetPopup.addItem(withTitle: current == nil ? "Current Settings" : settings.presets[current!].name)
        presetPopup.menu?.addItem(.separator())
        for (index, preset) in settings.presets.enumerated() {
            let item = NSMenuItem(title: preset.name, action: nil, keyEquivalent: ""); item.tag = index
            item.state = index == current ? .on : .off
            presetPopup.menu?.addItem(item)
        }
        if !settings.presets.isEmpty { presetPopup.menu?.addItem(.separator()) }
        let save = NSMenuItem(title: "Save Current Settings as Preset…", action: nil, keyEquivalent: ""); save.tag = -2
        presetPopup.menu?.addItem(save)
        if let current {
            let delete = NSMenuItem(title: "Delete “\(settings.presets[current].name)”", action: nil, keyEquivalent: ""); delete.tag = -3 - current
            presetPopup.menu?.addItem(delete)
        }
        presetPopup.selectItem(at: 0)
    }

    @objc func presetChosen() {
        let tag = presetPopup.selectedItem?.tag ?? 0
        if presetPopup.indexOfSelectedItem == 0 { return }
        if tag == -2 { savePreset() }
        else if tag <= -3 { settings.presets.remove(at: -3 - tag); persist() }
        else if settings.presets.indices.contains(tag) {
            let preset = settings.presets[tag]
            let destinationChanged = preset.destination != settings.destination
            settings.destination = preset.destination; settings.folderTemplate = preset.folderTemplate
            settings.openInDxO = preset.openInEditor; settings.eject = preset.eject
            persist(); loadInspector()
            if destinationChanged { destinationDidChange() } else { reorganize() }
            return
        }
        rebuildPresetMenu()
    }

    func savePreset() {
        let alert = NSAlert(); alert.messageText = "Save Import Preset"
        alert.informativeText = "Saves the destination, folder structure, and after-import options."
        let name = NSTextField(string: ""); name.placeholderString = "Preset name"; name.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = name; alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = name
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        settings.presets.removeAll { $0.name == title }
        settings.presets.append(ImportPreset(name: title, destination: settings.destination, folderTemplate: settings.folderTemplate,
                                             openInEditor: settings.openInDxO, eject: settings.eject))
        settings.presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persist()
    }

    @objc func chooseDestination() {
        guard state != .importing else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.message = "Choose the folder that will contain your organized photos."
        panel.directoryURL = URL(fileURLWithPath: settings.destination)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.destination = url.standardizedFileURL.path; persist(); loadInspector()
        destinationDidChange()
    }

    func destinationDidChange() {
        // Duplicate status depends on the destination: discard the preview and rescan.
        plan = nil; selection = []
        if source != nil { startScan() } else { refresh() }
    }

    @objc func structureChosen() {
        let index = structurePopup.indexOfSelectedItem
        if index < FolderStructure.all.count { templateField.stringValue = FolderStructure.all[index].template }
        templateField.isEditable = true
        organizationChanged()
        if index == FolderStructure.all.count { window?.makeFirstResponder(templateField) }
    }
    func controlTextDidChange(_ note: Notification) {
        if note.object as? NSTextField === templateField {
            structurePopup.selectItem(at: FolderStructure.all.firstIndex { $0.template == templateField.stringValue } ?? FolderStructure.all.count)
        }
        organizationChanged()
    }
    @objc func organizationChanged() {
        settings.folderTemplate = templateField.stringValue
        persist(); rebuildPresetMenu(); reorganize()
    }
    @objc func completionChanged() { settings.openInDxO = openEditor.state == .on; settings.eject = ejectCheck.state == .on; persist(); rebuildPresetMenu() }
    @objc func cardBehaviorChanged() { settings.cardInsertion = cardBehaviorPopup.indexOfSelectedItem == 0 ? .showAndScan : .indicate; persist() }
    @objc func toggleAdvanced() { advancedBox.isHidden = advancedToggle.state == .off }
    @objc func toggleAdvancedFromTitle() { advancedToggle.state = advancedToggle.state == .on ? .off : .on; toggleAdvanced() }
    func showAdvanced() { advancedToggle.state = .on; toggleAdvanced(); if inspectorItem.isCollapsed { toggleInspector() } }
    @objc func chooseEditor() {
        let panel = NSOpenPanel(); panel.message = "Choose the editor that opens newly imported folders (for example, DxO PhotoLab)."
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.photoLab = url.path; persist(); refresh()
    }
    @objc func showReports() {
        try? FileManager.default.createDirectory(at: Settings.reportsDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Settings.reportsDirectory)
    }
    @objc func toggleInspector() { inspectorItem.animator().isCollapsed.toggle() }

    var event: String { eventField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    var fallback: CaptureDay? {
        guard fallbackCheck.state == .on else { return nil }
        let parts = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: fallbackPicker.dateValue)
        return CaptureDay(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Apply the current structure, event, and fallback to the preview. Reads no files.
    func reorganize() {
        organizeError = nil
        if let current = plan {
            do {
                let updated = try current.organized(template: settings.folderTemplate, event: event, fallback: fallback)
                // Photos that just received an explicit date become selectable new photos;
                // photos that lost their date can no longer be imported.
                selection.formUnion(updated.importableNewGroups.subtracting(current.importableNewGroups))
                selection.subtract(current.importableNewGroups.subtracting(updated.importableNewGroups))
                plan = updated
            } catch { organizeError = error.localizedDescription }
        } else {
            do { _ = try Importer.folder(template: settings.folderTemplate, event: event, date: CaptureDay(year: 2026, month: 10, day: 4)) }
            catch { organizeError = error.localizedDescription }
        }
        refresh()
    }

    // MARK: Sources

    func cardsChanged(_ list: [URL], inserted: URL?) {
        cards = list
        newlyAvailable = newlyAvailable.filter { list.contains($0) }
        sidebar.reloadData(); selectSidebarRow()
        if let card = inserted {
            if settings.cardInsertion == .showAndScan && state == .idle {
                showWindow(nil); NSApp.activate(ignoringOtherApps: true)
                setSource(card, scan: true)
            } else {
                // Quiet mode, or work in progress: never switch away or interrupt.
                newlyAvailable.insert(card)
                sidebar.reloadData(); selectSidebarRow()
                status("Card “\(card.lastPathComponent)” is available. Select it to scan.")
            }
        } else if source == nil, state == .idle, let card = list.first, settings.cardInsertion == .showAndScan,
                  Date().timeIntervalSince(launched) < 10 {
            // A card already mounted when the app opens is shown like a newly inserted one.
            // Later list changes (such as ejecting the current card) never switch to another card.
            setSource(card, scan: true)
        }
        onStateChange?(); refresh()
    }

    func volumeUnmounted(_ volume: URL) {
        guard let current = source, current.path == volume.path || current.path.hasPrefix(volume.path + "/") else { return }
        scanToken?.cancel(); importToken?.cancel()
        scanGeneration += 1
        // An obsolete scan's completion is ignored, so leave the scanning state here.
        if state == .scanning { state = .idle; progressBar.stopAnimation(nil); thumbnails.cancelAll() }
        source = nil; plan = nil; preliminary = nil; selection = []; fallbackCheck.state = .off
        status("The source was removed. Verified copies are kept; reinsert it and scan again to continue.")
        sidebar.reloadData(); selectSidebarRow(); refresh(); onStateChange?()
    }

    var sidebarRows: [(title: String, url: URL?, icon: String, header: Bool)] {
        var rows: [(String, URL?, String, Bool)] = [("CARDS", nil, "", true)]
        rows += cards.isEmpty ? [("No cards detected", nil, "sdcard", false)] : cards.map { ($0.lastPathComponent, $0, "sdcard", false) }
        if let source, !cards.contains(source) { rows += [("FOLDER", nil, "", true), (source.lastPathComponent, source, "folder", false)] }
        return rows
    }
    func numberOfRows(in tableView: NSTableView) -> Int { sidebarRows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { sidebarRows[row].header }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { sidebarRows[row].url != nil && state != .importing }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = sidebarRows[row]
        if item.header {
            let field = NSTextField(labelWithString: item.title); field.font = .systemFont(ofSize: 11, weight: .semibold); field.textColor = .secondaryLabelColor
            return field
        }
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)!)
        image.contentTintColor = item.url == nil ? .tertiaryLabelColor : .controlAccentColor
        let text = NSTextField(labelWithString: item.title); text.lineBreakMode = .byTruncatingMiddle
        text.textColor = item.url == nil ? .secondaryLabelColor : .labelColor
        var views: [NSView] = [image, text]
        if let url = item.url, newlyAvailable.contains(url) {
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "New card")!.withSymbolConfiguration(.init(pointSize: 7, weight: .regular))!)
            dot.contentTintColor = .controlAccentColor; views.append(dot)
        }
        if let url = item.url, url == source, state == .importing || state == .scanning {
            let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil); views.append(spinner)
        }
        let stack = NSStackView(views: views); stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack); cell.textField = text; cell.imageView = image
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                                     stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        cell.setAccessibilityLabel(item.title + (item.url.map { newlyAvailable.contains($0) ? ", new card" : "" } ?? ""))
        return cell
    }
    func selectSidebarRow() {
        if let index = sidebarRows.firstIndex(where: { $0.url != nil && $0.url == source }) { sidebar.selectRowIndexes([index], byExtendingSelection: false) }
        else { sidebar.deselectAll(nil) }
    }
    @objc func sidebarClicked() {
        let row = sidebar.clickedRow >= 0 ? sidebar.clickedRow : sidebar.selectedRow
        guard row >= 0, let url = sidebarRows[row].url, state != .importing else { selectSidebarRow(); return }
        if url != source || plan == nil { setSource(url, scan: true) }
    }

    @objc func chooseSource() {
        guard state != .importing else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.message = "Choose a camera card, its DCIM folder, or another folder of photos."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSource(url, scan: true)
    }

    func setSource(_ url: URL, scan: Bool) {
        guard state != .importing else { status("An import is in progress. Choose another source when it finishes."); return }
        let standardized = url.standardizedFileURL
        source = cards.first { $0.standardizedFileURL.path == standardized.path } ?? standardized
        newlyAvailable.remove(source!)
        plan = nil; preliminary = nil; selection = []; dateFilter = nil
        // A fallback date is chosen for one source's undated photos; never carry it to another source.
        fallbackCheck.state = .off
        sidebar.reloadData(); selectSidebarRow()
        if scan { startScan() } else { refresh() }
        onStateChange?()
    }

    var sourceIsCard: Bool { source.map { cards.contains($0) } ?? false }

    // MARK: Scanning

    @objc func rescan() { if source != nil, state != .importing { startScan() } }

    func startScan() {
        guard let source, state != .importing else { return }
        guard let helper else { showError(ImportError("The app's built-in metadata reader is missing. Reinstall Andermic Photo Importer.")); return }
        scanToken?.cancel()
        scanGeneration += 1
        let generation = scanGeneration, token = Cancellation()
        scanToken = token
        thumbnails.cancelAll()
        plan = nil; preliminary = nil; selection = []; anchor = nil
        state = .scanning; scanStarted = Date()
        progressBar.isIndeterminate = true; progressBar.startAnimation(nil)
        status("Scanning “\(source.lastPathComponent)”…")
        var snapshot = settings
        // Scan with a valid structure; an invalid one is reported after the preview is ready.
        if (try? Importer.folder(template: settings.folderTemplate, event: event, date: CaptureDay(year: 2026, month: 10, day: 4))) == nil {
            snapshot.folderTemplate = Settings.defaultTemplate
        }
        let event = self.event, fallback = self.fallback
        refresh(); onStateChange?()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let value = try Importer.plan(source: source, settings: snapshot, event: snapshot.folderTemplate.contains("{event}") ? event : "", fallback: fallback,
                                              helper: helper, cancellation: token,
                                              progress: { update in DispatchQueue.main.async { self?.scanProgress(update, generation) } },
                                              discovered: { groups in DispatchQueue.main.async { self?.discovered(groups, generation) } })
                DispatchQueue.main.async { self?.scanFinished(value, generation) }
            } catch {
                DispatchQueue.main.async { self?.scanFailed(error, generation, token) }
            }
        }
    }

    func scanProgress(_ update: ImportProgress, _ generation: Int) {
        guard generation == scanGeneration, state == .scanning else { return }
        status(update.text)
        if let fraction = update.fraction { progressBar.isIndeterminate = false; progressBar.doubleValue = fraction }
    }
    func discovered(_ groups: [SourceGroup], _ generation: Int) {
        guard generation == scanGeneration, state == .scanning else { return }
        preliminary = groups
        refresh()
    }
    func scanFinished(_ value: ImportPlan, _ generation: Int) {
        // A result from an obsolete scan can never enable an import.
        guard generation == scanGeneration, value.source == source, value.root.path == URL(fileURLWithPath: settings.destination).standardizedFileURL.path else { return }
        plan = value; preliminary = nil
        state = .idle; progressBar.stopAnimation(nil)
        reorganize()
        selection = plan?.importableNewGroups ?? []
        sidebar.reloadData(); selectSidebarRow()
        let elapsed = Date().timeIntervalSince(scanStarted)
        let reads = value.scanReads
        status(String(format: "Scanned in %.1f s · %@ read to check %@ of photos.", elapsed,
                      ByteCountFormatter.string(fromByteCount: Int64(reads.total), countStyle: .file),
                      ByteCountFormatter.string(fromByteCount: Int64(value.files.reduce(0) { $0 + $1.size }), countStyle: .file)))
        refresh(); onStateChange?()
    }
    func scanFailed(_ error: Error, _ generation: Int, _ token: Cancellation) {
        guard generation == scanGeneration else { return }
        state = .idle; progressBar.stopAnimation(nil); preliminary = nil
        refresh(); sidebar.reloadData(); selectSidebarRow(); onStateChange?()
        if token.isCancelled { status("Scan stopped."); return }
        status(error.localizedDescription)
        showError(error)
    }

    // MARK: Grid

    func entries() -> [(String, String, [GridEntry])] {
        if let plan {
            let visible = plan.groups.filter { group in
                let members = plan.members(group)
                if case .some(let day) = dateFilter, group.date != day { return false }
                if !typeFilter.matches(members.map(\.source)) { return false }
                if showImported.state == .off && !(group.isNew || group.status == .sidecarChanged) { return false }
                return true
            }
            func entry(_ group: PhotoGroup) -> GridEntry {
                let members = plan.members(group)
                let primaries = members.filter { $0.role != .sidecar }
                let sidecars = members.filter { $0.role == .sidecar }.map { $0.source.pathExtension.uppercased() }
                let kinds = primaries.map { $0.source.pathExtension.uppercased() }.joined(separator: " + ") + (sidecars.isEmpty ? "" : " · " + sidecars.joined(separator: " "))
                let date = group.date.map(Self.display) ?? "No capture date"
                let files = members.count == 1 ? "1 file" : "\(members.count) files"
                let destination = group.folder.map { "\(plan.root.lastPathComponent)/\($0)/" }
                let thumbnail = primaries.first { $0.role == .image }?.source ?? primaries[0].source
                return GridEntry(id: group.id, name: group.name, thumbnail: thumbnail, kinds: kinds, fileCount: members.count,
                                 detail: "\(date) · \(files)", status: group.status, missingDate: group.date == nil, destination: destination,
                                 dateOrigin: group.date == nil ? nil : group.dateOrigin)
            }
            let fresh = visible.filter(\.isNew).map(entry)
            let other = visible.filter { !$0.isNew }.map(entry)
            var result: [(String, String, [GridEntry])] = []
            if !fresh.isEmpty { result.append(("New Photos", "\(fresh.count) \(fresh.count == 1 ? "photo" : "photos")", fresh)) }
            if !other.isEmpty { result.append(("Already Imported", "\(other.count)", other)) }
            return result
        }
        if let preliminary {
            let items = preliminary.enumerated().map { index, group in
                GridEntry(id: index, name: group.primaries[0].deletingPathExtension().lastPathComponent,
                          thumbnail: group.primaries.first { MediaTypes.role(of: $0) == .image } ?? group.primaries[0],
                          kinds: group.primaries.map { $0.pathExtension.uppercased() }.joined(separator: " + ") + (group.sidecars.isEmpty ? "" : " · +\(group.sidecars.count)"),
                          fileCount: group.members.count, detail: "Checking…", status: nil, missingDate: false, destination: nil)
            }
            return [("Scanning", "\(items.count) photos found", items)]
        }
        return []
    }

    static func display(_ day: CaptureDay) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .current
        let date = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { sections[section].entries.count }
    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: GroupTileItem.identifier, for: indexPath) as! GroupTileItem
        let entry = sections[indexPath.section].entries[indexPath.item]
        item.tile.configure(entry, checked: plan != nil && selection.contains(entry.id))
        item.tile.onToggle = { [weak self] flags in self?.toggle(entry.id, flags) }
        let key = ThumbnailLoader.key(entry.thumbnail)
        if let image = thumbnails.cached(key) { item.tile.setImage(image, placeholder: false) }
        else {
            item.tile.setImage(nil, placeholder: true)
            if !thumbnails.hasFailed(key) {
                item.operation = thumbnails.load(entry.thumbnail, key: key) { [weak item] image in
                    guard let item, item.tile.entry?.thumbnail == entry.thumbnail else { return }
                    item.tile.setImage(image, placeholder: image == nil)
                }
            }
        }
        return item
    }
    func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem, forRepresentedObjectAt indexPath: IndexPath) {
        // Cancel thumbnail work for tiles scrolled out of view.
        (item as? GroupTileItem)?.operation?.cancel()
    }
    func collectionView(_ collectionView: NSCollectionView, viewForSupplementaryElementOfKind kind: NSCollectionView.SupplementaryElementKind, at indexPath: IndexPath) -> NSView {
        let header = collectionView.makeSupplementaryView(ofKind: kind, withIdentifier: SectionHeader.identifier, for: indexPath) as! SectionHeader
        header.title.stringValue = sections[indexPath.section].title
        header.detail.stringValue = sections[indexPath.section].detail
        return header
    }
    func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> NSSize {
        NSSize(width: tileWidth, height: tileWidth * 0.75 + 38)
    }

    var visibleIDs: [Int] { sections.flatMap { $0.entries.filter(\.selectable).map(\.id) } }

    func toggle(_ id: Int, _ flags: NSEvent.ModifierFlags) {
        guard let plan, state == .idle, plan.groups[id].status != .imported else { return }
        let order = visibleIDs
        if flags.contains(.shift), let anchor, let from = order.firstIndex(of: anchor), let to = order.firstIndex(of: id) {
            let range = order[min(from, to)...max(from, to)]
            if selection.contains(anchor) { selection.formUnion(range) } else { selection.subtract(range) }
        } else {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        }
        updateTiles(); updateFooter()
    }
    func updateTiles() {
        for item in collection.visibleItems() {
            guard let tile = (item as? GroupTileItem)?.tile, let entry = tile.entry else { continue }
            tile.configure(entry, checked: plan != nil && selection.contains(entry.id))
        }
    }

    @objc func selectAllNew(_ sender: Any?) { guard plan != nil, state == .idle else { return }; selection.formUnion(visibleIDs.filter { plan!.importableNewGroups.contains($0) }); updateTiles(); updateFooter() }
    @objc func deselectAll(_ sender: Any?) { guard state == .idle else { return }; selection.subtract(visibleIDs); updateTiles(); updateFooter() }
    @objc override func selectAll(_ sender: Any?) { selectAllNew(sender) }

    @objc func filtersChanged() {
        typeFilter = TypeFilter(rawValue: typePopup.indexOfSelectedItem) ?? .all
        let index = datePopup.indexOfSelectedItem
        dateFilter = index > 0 && index <= dateOptions.count ? .some(dateOptions[index - 1]) : nil
        refresh()
    }
    @objc func resizeTiles() { tileWidth = CGFloat(sizeSlider.doubleValue); collection.collectionViewLayout?.invalidateLayout() }
    func zoom(by delta: CGFloat) { sizeSlider.doubleValue = Double(min(300, max(110, tileWidth + delta))); resizeTiles() }

    var dateOptions: [CaptureDay?] = []   // popup items after "All Dates"

    func rebuildDateFilter() {
        datePopup.removeAllItems(); dateOptions = []
        datePopup.addItem(withTitle: "All Dates")
        if let plan {
            var counts: [CaptureDay?: Int] = [:]
            for group in plan.groups { counts[group.date, default: 0] += 1 }
            for day in counts.keys.compactMap({ $0 }).sorted() {
                datePopup.addItem(withTitle: "\(Self.display(day))  (\(counts[day]!))"); dateOptions.append(day)
            }
            if let missing = counts[nil] { datePopup.addItem(withTitle: "No Capture Date  (\(missing))"); dateOptions.append(nil) }
        }
        if let current = dateFilter, let index = dateOptions.firstIndex(where: { $0 == current }) { datePopup.selectItem(at: index + 1) }
        else { dateFilter = nil; datePopup.selectItem(at: 0) }
    }

    // MARK: Refresh

    func refresh() {
        guard window != nil else { return }
        rebuildDateFilter()
        sections = entries().map { (title: $0.0, detail: $0.1, entries: $0.2) }
        collection.reloadData()
        let filtersEnabled = plan != nil && state == .idle
        for control in [datePopup, typePopup, showImported, sizeSlider] as [NSControl] { control.isEnabled = filtersEnabled || control === sizeSlider }

        titleLabel.stringValue = source?.lastPathComponent ?? "Import Photos"
        if let plan {
            let imported = plan.groups.filter { $0.status == .imported }.count
            let newGroups = plan.newGroups.count
            countsLabel.stringValue = "\(plan.groups.count) photos (\(plan.files.count) files) · \(newGroups) new · \(imported) already imported"
                + { let other = plan.ignored + plan.orphanSidecars.count; return other == 0 ? "" : " · \(other) other \(other == 1 ? "file" : "files") not imported" }()
        } else if let preliminary {
            countsLabel.stringValue = "\(preliminary.count) photos found · checking dates and duplicates…"
        } else {
            countsLabel.stringValue = source == nil ? "Insert a camera card or choose a folder to see its photos." : ""
        }
        if source == nil {
            emptyState.stringValue = "Insert a camera card, or choose a folder of photos.\nNothing is copied until you choose an import button."
        } else if state == .scanning && sections.isEmpty {
            emptyState.stringValue = "Looking for photos…"
        } else if plan != nil && sections.isEmpty {
            emptyState.stringValue = "No photos match these filters."
        } else { emptyState.stringValue = "" }
        emptyState.isHidden = emptyState.stringValue.isEmpty

        // Inspector state
        let editing = state != .importing
        for control in [presetPopup, destinationButton, structurePopup, templateField, eventField, fallbackCheck, cardBehaviorPopup] as [NSControl] { control.isEnabled = editing }
        templateField.isEditable = editing
        fallbackPicker.isEnabled = editing && fallbackCheck.state == .on
        fallbackBox.isHidden = !(plan?.groups.contains { $0.date == nil && $0.isNew } ?? false) && fallbackCheck.state == .off
        openEditor.title = "Open new folders in \(settings.editorName)"
        openEditor.isEnabled = editing && settings.editorAvailable
        editorNote.stringValue = settings.editorAvailable ? "" : "\(settings.editorName) was not found. Choose an editor in Advanced to enable this."
        editorNote.isHidden = settings.editorAvailable
        editorPath.stringValue = settings.photoLab.isEmpty ? "None selected" : settings.photoLab
        ejectCheck.isEnabled = editing && sourceIsCard
        ejectCheck.toolTip = sourceIsCard ? nil : "Only a detected camera card can be ejected."
        updatePreview()
        updateFooter()
    }

    func updatePreview() {
        let root = URL(fileURLWithPath: settings.destination)
        if let organizeError {
            previewLabel.stringValue = organizeError; previewLabel.textColor = .systemRed; return
        }
        previewLabel.textColor = .secondaryLabelColor
        let base = "\(root.lastPathComponent)/"
        guard let plan else {
            let example = (try? Importer.folder(template: settings.folderTemplate, event: event.isEmpty ? "Event Name" : event, date: CaptureDay(year: 2026, month: 10, day: 4))) ?? ""
            previewLabel.stringValue = "Example: \(base)\(example)/IMG_0001.JPG"
            return
        }
        let chosen = selection.isEmpty ? plan.newGroups : selection
        var folders: [String: (groups: Int, files: Int)] = [:]
        for id in chosen {
            let group = plan.groups[id]
            let newFiles = plan.members(group).filter { $0.existing == nil }.count
            guard newFiles > 0 else { continue }
            let key = group.folder ?? "⚠︎ needs a capture date"
            folders[key, default: (0, 0)].groups += 1; folders[key]!.files += newFiles
        }
        if folders.isEmpty { previewLabel.stringValue = "Nothing new to import."; return }
        let lines = folders.keys.sorted().prefix(8).map { key in
            "\(key.hasPrefix("⚠︎") ? key : base + key + "/")\n   \(folders[key]!.groups) photos · \(folders[key]!.files) files"
        }
        previewLabel.stringValue = (selection.isEmpty ? "All new photos:\n" : "Selected photos:\n") + lines.joined(separator: "\n")
            + (folders.count > 8 ? "\n…and \(folders.count - 8) more folders" : "")
    }

    var visibleSelection: Set<Int> { selection.intersection(visibleIDs) }

    var planIsCurrent: Bool {
        guard let plan, let source, organizeError == nil else { return false }
        return plan.source == source && plan.root.path == URL(fileURLWithPath: settings.destination).standardizedFileURL.path
            && plan.settings.folderTemplate == settings.folderTemplate && plan.fallback == fallback
            && (plan.event == event || !settings.folderTemplate.contains("{event}"))
    }

    func updateFooter() {
        let idle = state == .idle
        cancelButton.isHidden = idle
        progressBar.isHidden = idle
        if state != .idle { progressBar.startAnimation(nil) } else { progressBar.stopAnimation(nil) }
        guard let plan, idle else {
            importAllButton.title = "Import All New"; importSelectedButton.title = "Import Selected"
            importAllButton.isEnabled = false; importSelectedButton.isEnabled = false
            selectionLabel.stringValue = state == .importing ? "Importing…" : ""
            updatePreview()
            return
        }
        let chosen = visibleSelection
        let hidden = selection.count - chosen.count
        let newGroups = plan.importableNewGroups
        let undated = plan.newGroups.count - newGroups.count
        importSelectedButton.title = "Import \(chosen.count) Selected"
        importAllButton.title = "Import All New (\(newGroups.count))"
        let current = planIsCurrent
        importSelectedButton.isEnabled = current && !chosen.isEmpty && plan.missingDates(in: chosen) == 0
        importAllButton.isEnabled = current && !newGroups.isEmpty
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(plan.bytes(in: chosen)), countStyle: .file)
        var text = chosen.isEmpty ? "No photos selected" : "\(chosen.count) selected · \(plan.fileCount(in: chosen)) files · \(bytes) to copy"
        if hidden > 0 { text += " · \(hidden) hidden by filters won’t be imported" }
        let missing = plan.missingDates(in: chosen)
        if missing > 0 { text += " · \(missing) selected files need a capture date" }
        selectionLabel.stringValue = text
        let undatedNotice = "no capture date and"
        if undated > 0 {
            status("\(undated) new \(undated == 1 ? "photo has" : "photos have") \(undatedNotice) \(undated == 1 ? "is" : "are") excluded until you choose a date in Import Options.")
        } else if statusLabel.stringValue.contains(undatedNotice) { status("") }
        updatePreview()
    }

    func status(_ text: String) { statusLabel.stringValue = text; statusLabel.toolTip = text }

    // MARK: Importing

    @objc func importSelected() { startImport(visibleSelection) }
    @objc func importAllNew() { if let plan { startImport(plan.importableNewGroups) } }

    func startImport(_ groups: Set<Int>) {
        guard state == .idle, let plan, planIsCurrent, !groups.isEmpty else { return }
        guard plan.missingDates(in: groups) == 0 else {
            showError(ImportError("Some selected photos have no capture date. Choose a fallback date in Import Options, or deselect them.")); return
        }
        window?.makeFirstResponder(nil)
        let volume = ejectableVolume()
        let token = Cancellation(); importToken = token
        state = .importing
        thumbnails.concurrency = 1   // leave card bandwidth for copying
        progressBar.isIndeterminate = false; progressBar.doubleValue = 0
        status("Preparing to import \(groups.count) photos…")
        refresh(); sidebar.reloadData(); selectSidebarRow(); onStateChange?()
        let snapshot = settings
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let result = try Importer.run(plan, selection: groups, cancellation: token, progress: { update in
                    DispatchQueue.main.async {
                        self?.status(update.text)
                        if let fraction = update.fraction { self?.progressBar.doubleValue = fraction }
                    }
                })
                DispatchQueue.main.async { self?.importFinished(result, plan: plan, settings: snapshot, volume: volume) }
            } catch {
                DispatchQueue.main.async { self?.importFailed(error, plan: plan, groups: groups) }
            }
        }
    }

    func importFinished(_ result: ImportResult, plan: ImportPlan, settings snapshot: Settings, volume: URL?) {
        self.plan = plan.applying(result.outcomes)
        selection = self.plan!.newGroups.intersection(selection)
        thumbnails.concurrency = 3
        var detail = "\(result.copied) new \(result.copied == 1 ? "file" : "files") copied and verified from \(result.groups) \(result.groups == 1 ? "photo" : "photos")."
        if result.skipped > 0 { detail += " \(result.skipped) already present and verified." }
        if !result.notes.isEmpty { detail += "\n\n" + result.notes.joined(separator: "\n") }
        if snapshot.openInDxO && !result.folders.isEmpty {
            let app = URL(fileURLWithPath: snapshot.photoLab)
            if snapshot.editorAvailable {
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                NSWorkspace.shared.open(result.folders, withApplicationAt: app, configuration: configuration) { _, error in
                    if let error { DispatchQueue.main.async { self.showError(ImportError("Import succeeded, but \(snapshot.editorName) could not open the folders: \(error.localizedDescription)")) } }
                }
            } else { detail += "\n\n\(snapshot.editorName) was not found, so folders were not opened." }
        }
        status("Import complete: \(result.copied) copied and verified.")
        // Never eject a card that still holds new photos the user has not imported.
        let remaining = self.plan!.newGroups.count
        if snapshot.eject, volume != nil, remaining > 0 {
            detail += "\n\nThe card was not ejected because \(remaining) new \(remaining == 1 ? "photo remains" : "photos remain") on it."
        }
        if snapshot.eject, let volume, remaining == 0 {
            status("Import verified. Ejecting “\(volume.lastPathComponent)”…")
            DispatchQueue.global(qos: .userInitiated).async {
                var failure: Error?
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } catch { failure = error }
                DispatchQueue.main.async {
                    self.state = .idle; self.refresh(); self.onStateChange?()
                    self.showResult(result, detail: detail + (failure.map { "\n\nThe card could not be ejected: \($0.localizedDescription) Eject it in Finder." } ?? "\n\nThe card was safely ejected."))
                    self.finishWork()
                }
            }
        } else {
            state = .idle; refresh(); sidebar.reloadData(); selectSidebarRow(); onStateChange?()
            showResult(result, detail: detail)
            finishWork()
        }
    }

    func importFailed(_ error: Error, plan: ImportPlan, groups: Set<Int>) {
        state = .idle; thumbnails.concurrency = 3
        if let failure = error as? ImportFailure, source == plan.source {
            self.plan = plan.applying(failure.outcomes)
            selection = self.plan!.newGroups.intersection(groups.union(selection))
        }
        refresh(); sidebar.reloadData(); selectSidebarRow(); onStateChange?()
        let failure = error as? ImportFailure
        status(failure?.cancelled == true ? "Import stopped. \(failure!.copied) verified copies kept." : "Import did not finish.")
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = failure?.cancelled == true ? "Import stopped" : "Import did not finish"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        let canRescan = failure != nil && source != nil
        if canRescan { alert.addButton(withTitle: "Scan Again") }
        if failure != nil { alert.addButton(withTitle: "Show Report") }
        present(alert) { answer in
            if canRescan && answer == .alertSecondButtonReturn { self.startScan() }
            else if let failure, answer == (canRescan ? .alertThirdButtonReturn : .alertSecondButtonReturn) {
                NSWorkspace.shared.activateFileViewerSelecting([failure.receipt])
            }
            self.finishWork()
        }
    }

    func finishWork() { if quitAfterWork { NSApp.terminate(nil) } }

    func showResult(_ result: ImportResult, detail: String) {
        let alert = NSAlert(); alert.messageText = "Import complete"; alert.informativeText = detail
        alert.addButton(withTitle: "Done")
        if !result.folders.isEmpty { alert.addButton(withTitle: "Show in Finder") }
        alert.addButton(withTitle: "Show Report")
        present(alert) { answer in
            if answer == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(result.folders.isEmpty ? [result.receipt] : result.folders) }
            if answer == .alertThirdButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([result.receipt]) }
        }
    }

    /// Attach alerts to the window when it is visible; otherwise (window closed, app in the menu bar) show them as panels.
    func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void = { _ in }) {
        if let window, window.isVisible, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: completion) }
        else { completion(alert.runModal()) }
    }

    /// Only a detected camera card that does not hold the destination may be ejected.
    func ejectableVolume() -> URL? {
        guard let source, cards.contains(source),
              let volume = try? source.resourceValues(forKeys: [.volumeURLKey]).volume,
              volume.path.hasPrefix("/Volumes/"), !settings.destination.hasPrefix(volume.path + "/"), settings.destination != volume.path else { return nil }
        return volume
    }

    @objc func cancelWork() {
        switch state {
        case .scanning: scanToken?.cancel(); status("Stopping scan…")
        case .importing: importToken?.cancel(); cancelButton.isEnabled = false; status("Stopping safely after the current photo… verified copies are kept.")
        case .idle: break
        }
    }

    func showError(_ error: Error) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Andermic Photo Importer"; alert.informativeText = error.localizedDescription
        present(alert)
    }

    func windowDidBecomeKey(_ notification: Notification) { cancelButton.isEnabled = true }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }
