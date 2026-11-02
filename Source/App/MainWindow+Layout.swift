import AppKit

/// Building the window: sidebar, grid with header and footer, and the Import Options panel.
extension MainWindowController {
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
        let hint = small("Connect a USB camera, insert a card, or choose a folder.")
        let footer = NSStackView(views: [choose, hint]); footer.orientation = .vertical; footer.alignment = .leading; footer.spacing = 8
        let view = NSView(); Theme.fill(view, Theme.chrome)
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
        titleLabel.font = Theme.font("heading"); titleLabel.textColor = Theme.text; titleLabel.lineBreakMode = .byTruncatingMiddle
        countsLabel.font = Theme.font("secondary"); countsLabel.textColor = Theme.muted
        countsLabel.lineBreakMode = .byTruncatingTail
        countsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        for icon in [smallIcon, largeIcon] { icon.contentTintColor = Theme.muted }
        let titles = NSStackView(views: [titleLabel, countsLabel]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectAllButton.target = self; selectAllButton.action = #selector(selectAll(_:))
        selectAllNewButton.target = self; selectAllNewButton.action = #selector(selectAllNew(_:))
        deselectAllButton.target = self; deselectAllButton.action = #selector(deselectAll(_:))
        selectAllButton.toolTip = "Select every photo matching the current filters, including already imported photos. Existing copies are reverified when importing."
        selectAllNewButton.toolTip = "Select only new, dated photos matching the current filters."
        deselectAllButton.toolTip = "Clear the entire photo selection, including photos hidden by filters."
        for button in [selectAllButton, selectAllNewButton, deselectAllButton] { button.bezelStyle = .rounded; button.controlSize = .small }
        let selectionActions = NSStackView(views: [selectAllButton, selectAllNewButton, deselectAllButton]); selectionActions.spacing = 6
        let titleRow = NSStackView(views: [titles, NSView(), selectionActions]); titleRow.spacing = 12; titleRow.alignment = .centerY
        let filters = NSStackView(views: [datePopup, typePopup, showImported, NSView(), smallIcon, sizeSlider, largeIcon])
        filters.spacing = 10; filters.alignment = .centerY
        let header = NSStackView(views: [titleRow, filters]); header.orientation = .vertical; header.alignment = .leading; header.spacing = 10
        filters.translatesAutoresizingMaskIntoConstraints = false

        let layout = NSCollectionViewFlowLayout()
        layout.minimumInteritemSpacing = 14; layout.minimumLineSpacing = 18
        layout.sectionInset = NSEdgeInsets(top: 6, left: 20, bottom: 22, right: 20)
        layout.headerReferenceSize = NSSize(width: 0, height: 34)
        collection.wantsLayer = true
        collection.collectionViewLayout = layout
        collection.dataSource = self; collection.delegate = self
        collection.isSelectable = false
        collection.onSelectAll = { [weak self] in self?.selectAll(nil) }
        collection.backgroundColors = [Theme.ground]
        collection.register(GroupTileItem.self, forItemWithIdentifier: GroupTileItem.identifier)
        collection.register(SectionHeader.self, forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader, withIdentifier: SectionHeader.identifier)
        collection.setAccessibilityLabel("Photos to import")
        gridScroll.documentView = collection; gridScroll.hasVerticalScroller = true; gridScroll.drawsBackground = false
        gridScroll.onDropFolder = { [weak self] url in self?.setSource(url, scan: true) }
        emptyState.alignment = .center; emptyState.textColor = Theme.muted; emptyState.font = .systemFont(ofSize: 13)

        progressBar.widthAnchor.constraint(equalToConstant: 140).isActive = true
        statusLabel.font = Theme.font("secondary"); statusLabel.textColor = Theme.muted; statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        selectionLabel.font = .systemFont(ofSize: 12, weight: .medium); selectionLabel.lineBreakMode = .byTruncatingTail
        selectionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cancelButton.target = self; cancelButton.action = #selector(cancelWork); cancelButton.keyEquivalent = "\u{1b}"
        importAllButton.target = self; importAllButton.action = #selector(importAllNew); importAllButton.bezelStyle = .rounded
        importSelectedButton.target = self; importSelectedButton.action = #selector(importSelected); importSelectedButton.bezelStyle = .rounded
        importSelectedButton.keyEquivalent = "\r"
        let statusStack = NSStackView(views: [selectionLabel, statusLabel]); statusStack.orientation = .vertical; statusStack.alignment = .leading; statusStack.spacing = 1
        statusStack.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [progressBar, statusStack, NSView(), cancelButton, importAllButton, importSelectedButton])
        footer.spacing = 10; footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 12, right: 20)

        let view = NSView(); Theme.fill(view, Theme.chrome)
        let topRule = NSBox(), bottomRule = NSBox(); topRule.boxType = .separator; bottomRule.boxType = .separator
        for item in [header, topRule, gridScroll, emptyState, bottomRule, footer] as [NSView] { item.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(item) }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            titleRow.widthAnchor.constraint(equalTo: header.widthAnchor),
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
        previewLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular); previewLabel.textColor = Theme.muted
        previewLabel.setAccessibilityLabel("Destination preview")
        fallbackPicker.datePickerStyle = .textFieldAndStepper; fallbackPicker.datePickerElements = [.yearMonthDay]; fallbackPicker.dateValue = Date()
        fallbackPicker.target = self; fallbackPicker.action = #selector(organizationChanged)
        fallbackCheck.target = self; fallbackCheck.action = #selector(organizationChanged)
        fallbackBox.orientation = .vertical; fallbackBox.alignment = .leading; fallbackBox.spacing = 6
        for view in [section("Missing capture dates"), small("Some photos have no capture date. Nothing is guessed: choose a date for them, or leave them unselected."), fallbackCheck, fallbackPicker]
        {
            fallbackBox.addArrangedSubview(view)
        }
        openEditor.target = self; openEditor.action = #selector(completionChanged)
        ejectCheck.target = self; ejectCheck.action = #selector(completionChanged)
        editorNote.font = Theme.font("note"); editorNote.textColor = Theme.muted
        advancedToggle.bezelStyle = .disclosure; advancedToggle.setButtonType(.pushOnPushOff); advancedToggle.state = .off
        advancedToggle.target = self; advancedToggle.action = #selector(toggleAdvanced); advancedToggle.setAccessibilityLabel("Show advanced options")
        let advancedTitle = NSButton(title: "Advanced", target: self, action: #selector(toggleAdvancedFromTitle)); advancedTitle.isBordered = false
        advancedTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        let advancedRow = NSStackView(views: [advancedToggle, advancedTitle]); advancedRow.spacing = 2
        cardBehaviorPopup.addItems(withTitles: ["Show window and scan the card", "Only show that a card is available", "Scan in the background"])
        cardBehaviorPopup.target = self; cardBehaviorPopup.action = #selector(cardBehaviorChanged)
        cardBehaviorPopup.setAccessibilityLabel("When a card is inserted")
        backgroundLaunch.target = self; backgroundLaunch.action = #selector(backgroundLaunchChanged)
        otherCardPopup.addItems(withTitles: ["Show as new", "Treat as imported"])
        otherCardPopup.target = self; otherCardPopup.action = #selector(otherCardChanged)
        otherCardPopup.setAccessibilityLabel("Photos already imported from the camera's other card")
        let loginItems = NSButton(title: "Login Items…", target: NSApp.delegate, action: #selector(AppDelegate.showLoginItems))
        editorPath.font = Theme.font("note"); editorPath.textColor = Theme.muted; editorPath.lineBreakMode = .byTruncatingMiddle
        let chooseEditor = NSButton(title: "Choose Editor…", target: self, action: #selector(chooseEditor))
        let reportsButton = NSButton(title: "Show Import Reports", target: self, action: #selector(showReports))
        let noticesButton = NSButton(title: "Third-Party Notices…", target: NSApp.delegate, action: #selector(AppDelegate.showNotices))
        advancedBox.orientation = .vertical; advancedBox.alignment = .leading; advancedBox.spacing = 8
        for view in [
            label("Startup"), backgroundLaunch, loginItems,
            small("To start at login, add this app under Open at Login in macOS Login Items. The menu-bar option keeps its window closed on launch."),
            label("When a card is inserted"), cardBehaviorPopup,
            small("Scanning only previews. Copying always waits for an import button, and an import in progress is never interrupted."),
            label("Photos already imported from the camera's other card"), otherCardPopup,
            small(
                "Cameras recording to two cards mark each copy with its card slot, so the copies are not byte-identical. Treat as imported matches the camera serial number, capture time, metadata, size, and samples."
            ),
            label("Editor handoff"), editorPath, chooseEditor,
            label("Folder template tokens"),
            small("{YYYY} year · {YY} short year · {MM} month · {DD} day · {event} event name. Use / between folder levels. Each photo uses its own camera-recorded capture day."),
            reportsButton, noticesButton,
        ] {
            advancedBox.addArrangedSubview(view)
        }
        advancedBox.isHidden = true

        let folderIcon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)!); folderIcon.contentTintColor = Theme.accent
        let destinationRow = NSStackView(views: [folderIcon, destinationPath, destinationButton]); destinationRow.spacing = 6
        destinationPath.setContentHuggingPriority(.defaultLow, for: .horizontal)
        destinationPath.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = NSStackView(); content.orientation = .vertical; content.alignment = .leading; content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 20, right: 16)
        let views: [NSView] = [
            heading("Import Options"),
            section("Preset"), presetPopup,
            divider(),
            section("Destination"), destinationRow,
            section("Folder structure"), structurePopup, templateField,
            section("Event name (optional)"), eventField,
            small("Only used by structures that include {event}. Photos from several days go into each day's folder."),
            section("Resulting folders"), previewLabel,
            fallbackBox,
            divider(),
            section("After import"), openEditor, editorNote, ejectCheck,
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
        let view = NSView(); Theme.fill(view, Theme.chrome); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor), content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        return view
    }

    func heading(_ text: String) -> NSTextField { let field = NSTextField(labelWithString: text); field.font = Theme.font("panel"); field.textColor = Theme.text; return field }
    func section(_ text: String) -> NSTextField { Theme.sectionLabel(text) }
    func label(_ text: String) -> NSTextField { let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 12, weight: .medium); return field }
    func small(_ text: String) -> NSTextField { let field = NSTextField(wrappingLabelWithString: text); field.font = Theme.font("note"); field.textColor = Theme.muted; return field }
    func divider() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
