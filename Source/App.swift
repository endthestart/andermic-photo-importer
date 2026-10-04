import AppKit
import ImageIO

final class ImportWindow: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    var window: NSWindow!
    var statusItem: NSStatusItem!
    let source = NSTextField(string: "")
    let root = NSTextField(string: "")
    let event = NSTextField(string: "")
    let template = NSTextField(string: "")
    let presets = NSPopUpButton()
    let cardMenu = NSPopUpButton()
    let fallback = NSButton(checkboxWithTitle: "Use this date if capture date is missing", target: nil, action: nil)
    let datePicker = NSDatePicker()
    let openDxO = NSButton(checkboxWithTitle: "Open new folders in DxO PhotoLab", target: nil, action: nil)
    let eject = NSButton(checkboxWithTitle: "Eject card after successful verification", target: nil, action: nil)
    let onlyNew = NSButton(checkboxWithTitle: "Show only new files", target: nil, action: nil)
    let summary = NSTextField(labelWithString: "Select a card or folder, name your event, then scan for new photos.")
    let pathPreview = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "Ready. Nothing is copied until you click Import New Photos.")
    let table = NSTableView()
    let spinner = NSProgressIndicator()
    let scan = NSButton(title: "Scan for New Photos", target: nil, action: nil)
    let importButton = NSButton(title: "Import New Photos", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    var settings = Settings.load()
    var plan: ImportPlan?
    var rows: [PlannedFile] = []
    var token: Cancellation?
    var busy = false
    var controlViews: [NSControl] = []
    var cards: [URL] = []
    var cardGeneration = 0
    var pendingCards: [URL] = []
    var thumbnails: [String: NSImage] = [:]
    var pendingThumbnails = Set<String>()
    let thumbnailQueue = DispatchQueue(label: "local.photoimport.thumbnails", qos: .utility)
    let formats = ["Year / Month-Day - Event", "Year / Full Date", "Year / Month / Day", "Year / Event", "Event only", "Custom…"]
    let patterns = ["{YYYY}/{MM}-{DD} - {event}", "{YYYY}/{YYYY}-{MM}-{DD}", "{YYYY}/{MM}/{DD}", "{YYYY}/{event}", "{event}"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        createMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Andermic Photo Importer"; window.minSize = NSSize(width: 1100, height: 700); window.center()
        window.isReleasedWhenClosed = false
        let content = NSView(); window.contentView = content
        let title = NSTextField(labelWithString: "Import new photos")
        title.font = .systemFont(ofSize: 25, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Copy originals into your folders · Verify every file · Keep everything local")
        subtitle.textColor = .secondaryLabelColor
        let header = stack([title, subtitle], spacing: 5)
        header.heightAnchor.constraint(equalToConstant: 58).isActive = true
        let sourceButton = button("Choose Card or Folder…", #selector(chooseSource))
        let destinationButton = button("Choose Destination…", #selector(chooseRoot))
        source.placeholderString = "/Volumes/Camera Card"; source.isEditable = false
        source.lineBreakMode = .byTruncatingMiddle
        cardMenu.target = self; cardMenu.action = #selector(selectCard)
        let left = stack([section("FROM"), cardMenu, source, sourceButton,
                          separator(), section("IMPORT METHOD"), label("Copy only new files", bold: true),
                          help("Existing files are matched by SHA-256 contents across the entire destination library. Originals stay on the card."),
                          separator(), onlyNew], spacing: 12)
        left.widthAnchor.constraint(equalToConstant: 215).isActive = true
        root.stringValue = settings.destination; root.isEditable = false; root.lineBreakMode = .byTruncatingMiddle
        event.placeholderString = "Soccer Tournament"
        template.stringValue = settings.folderTemplate
        presets.addItems(withTitles: formats)
        presets.selectItem(at: patterns.firstIndex(of: settings.folderTemplate) ?? 5)
        presets.target = self; presets.action = #selector(changePreset)
        datePicker.datePickerStyle = .textFieldAndStepper; datePicker.datePickerElements = [.yearMonthDay]
        datePicker.dateValue = Date(); datePicker.isEnabled = false
        fallback.target = self; fallback.action = #selector(changeOptions)
        openDxO.state = settings.openInDxO ? .on : .off; eject.state = settings.eject ? .on : .off
        openDxO.target = self; openDxO.action = #selector(changeOptions)
        eject.target = self; eject.action = #selector(changeOptions)
        datePicker.target = self; datePicker.action = #selector(changeOptions)
        let settingsButton = button("Settings…", #selector(showSettings))
        let right = stack([section("TO"), root, destinationButton,
                           section("EVENT NAME"), event,
                           section("ORGANIZE INTO FOLDERS"), presets, template,
                           help("Tokens: {YYYY}  {YY}  {MM}  {DD}  {event}\nUse / between folder levels."), pathPreview,
                           separator(), fallback, datePicker,
                           separator(), openDxO, eject, settingsButton], spacing: 10)
        right.widthAnchor.constraint(equalToConstant: 310).isActive = true
        for (id, name, width) in [("file", "Photo / Video", 150.0), ("date", "Capture Date", 90.0), ("action", "Import", 100.0), ("folder", "Destination Folder", 180.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = name; column.width = width
            column.minWidth = id == "file" ? 130 : 85; table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.rowHeight = 40; table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder; scroll.translatesAutoresizingMaskIntoConstraints = false
        summary.font = .systemFont(ofSize: 12, weight: .semibold); summary.lineBreakMode = .byTruncatingTail
        let center = stack([summary, scroll], spacing: 12)
        let body = NSStackView(views: [left, separator(vertical: true), center, separator(vertical: true), right])
        body.orientation = .horizontal; body.alignment = .top; body.distribution = .fill; body.spacing = 18
        center.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scan.target = self; scan.action = #selector(scanSource)
        importButton.target = self; importButton.action = #selector(startImport); importButton.bezelStyle = .rounded; importButton.isEnabled = false
        importButton.keyEquivalent = "\r"
        cancelButton.target = self; cancelButton.action = #selector(cancelWork); cancelButton.isHidden = true
        onlyNew.target = self; onlyNew.action = #selector(filterRows); onlyNew.state = .on
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.font = .systemFont(ofSize: 12); status.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [spinner, status, cancelButton, scan, importButton])
        footer.orientation = .horizontal; footer.spacing = 12; footer.alignment = .centerY
        footer.heightAnchor.constraint(equalToConstant: 40).isActive = true
        let layout = stack([header, separator(), body, separator(), footer], spacing: 18)
        layout.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(layout)
        NSLayoutConstraint.activate([layout.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                                     layout.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                                     layout.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),
                                     layout.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -22),
                                     scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 320)])
        controlViews = [sourceButton, destinationButton, settingsButton, cardMenu, event, template, presets, fallback, datePicker, openDxO, eject]
        for field in [event, template] { field.delegate = self }
        updatePathPreview(); refreshCards()
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(mounted(_:)), name: NSWorkspace.didMountNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmounted(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func createMenu() {
        let menu = NSMenu(), appMenu = NSMenu(); let item = NSMenuItem(); item.submenu = appMenu; menu.addItem(item)
        appMenu.addItem(withTitle: "Show Andermic Photo Importer", action: #selector(showWindow), keyEquivalent: "0").target = self
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "Quit Andermic Photo Importer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenuItem(); edit.title = "Edit"; let editMenu = NSMenu(title: "Edit"); edit.submenu = editMenu
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(edit); NSApp.mainMenu = menu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.badge.ellipsis", accessibilityDescription: "Andermic Photo Importer")
        let tray = NSMenu(); tray.addItem(withTitle: "Show Andermic Photo Importer", action: #selector(showWindow), keyEquivalent: "").target = self
        tray.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = tray
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if busy {
            let alert = NSAlert(); alert.messageText = "Cancel the current operation and quit?"
            alert.informativeText = "Verified copies stay in place. The card will stay mounted. You can safely import again later."
            alert.addButton(withTitle: "Keep Working"); alert.addButton(withTitle: "Cancel and Quit")
            if alert.runModal() == .alertSecondButtonReturn { token?.cancel(); quitAfterWork = true }
            return .terminateCancel
        }
        return .terminateNow
    }
    var quitAfterWork = false
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func stack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let view = NSStackView(views: views); view.orientation = .vertical; view.alignment = .leading; view.spacing = spacing
        for child in views where !(child is NSBox) { child.translatesAutoresizingMaskIntoConstraints = false; child.widthAnchor.constraint(equalTo: view.widthAnchor).isActive = true }
        return view
    }
    func separator(vertical: Bool = false) -> NSBox {
        let box = NSBox(); box.boxType = .separator
        if vertical { box.widthAnchor.constraint(equalToConstant: 1).isActive = true } else { box.heightAnchor.constraint(equalToConstant: 1).isActive = true }
        return box
    }
    func section(_ text: String) -> NSTextField { let field = label(text, bold: true); field.font = .systemFont(ofSize: 10, weight: .bold); field.textColor = .secondaryLabelColor; return field }
    func label(_ text: String, bold: Bool = false) -> NSTextField { let field = NSTextField(labelWithString: text); field.font = .systemFont(ofSize: 12, weight: bold ? .semibold : .regular); return field }
    func help(_ text: String) -> NSTextField { let field = NSTextField(wrappingLabelWithString: text); field.font = .systemFont(ofSize: 11); field.textColor = .secondaryLabelColor; return field }
    func button(_ title: String, _ action: Selector) -> NSButton { NSButton(title: title, target: self, action: action) }
    func chooseDirectory(message: String) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }
    @objc func chooseSource() { if let url = chooseDirectory(message: "Choose the camera card, its DCIM folder, or another photo folder.") { setSource(url) } }
    @objc func chooseRoot() {
        if let url = chooseDirectory(message: "Choose the existing root folder that will contain your organized photos.") { root.stringValue = url.path; invalidate(); updatePathPreview() }
    }
    func setSource(_ url: URL) {
        source.stringValue = url.path; invalidate(); updateEjectAvailability()
        if let index = cards.firstIndex(of: url) { cardMenu.selectItem(at: index) }
        else { cardMenu.selectItem(at: cards.count) }
    }
    func updateCardMenu() {
        cardMenu.removeAllItems(); cardMenu.addItems(withTitles: cards.map(\.lastPathComponent)); cardMenu.addItem(withTitle: "Other folder…")
        if let index = cards.firstIndex(where: { $0.path == source.stringValue }) { cardMenu.selectItem(at: index) } else { cardMenu.selectItem(at: cards.count) }
    }
    func refreshCards(activate mounted: URL? = nil) {
        cardGeneration += 1; let generation = cardGeneration
        let destination = root.stringValue
        cards = []; updateCardMenu()
        // Mounted volumes can be sleeping, unavailable, or awaiting macOS permissions.
        // Probe independently off the main thread; one stalled disk cannot block other cards or the GUI.
        DispatchQueue.global(qos: .utility).async {
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            for volume in volumes where volume.path.hasPrefix("/Volumes/") && !destination.hasPrefix(volume.path + "/") && destination != volume.path {
                DispatchQueue.global(qos: .utility).async {
                    guard let values = try? volume.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]),
                          values.volumeIsLocal == true,
                          values.volumeIsRemovable == true || (values.volumeIsEjectable == true && values.volumeIsInternal != true) else { return }
                    let found = ["DCIM", "dcim", "Dcim"].contains { name in
                        var directory: ObjCBool = false
                        return FileManager.default.fileExists(atPath: volume.appendingPathComponent(name).path, isDirectory: &directory) && directory.boolValue
                    }
                    guard found else { return }
                    DispatchQueue.main.async {
                        guard self.cardGeneration == generation else { return }
                        if !self.cards.contains(volume) { self.cards.append(volume); self.cards.sort { $0.path < $1.path } }
                        self.updateCardMenu()
                        if mounted == volume {
                            if self.busy { self.pendingCards.append(volume) }
                            else { self.setSource(volume); self.showWindow(); self.window.makeFirstResponder(self.event); self.status.stringValue = "Card detected: \(volume.lastPathComponent). Enter an event name, then scan." }
                        } else if self.source.stringValue.isEmpty && !self.busy {
                            self.setSource(volume); self.window.makeFirstResponder(self.event)
                            self.status.stringValue = "Card detected. Enter an event name and scan for new photos."
                        }
                        self.updateEjectAvailability()
                    }
                }
            }
        }
    }
    @objc func selectCard() {
        if cardMenu.indexOfSelectedItem < cards.count { setSource(cards[cardMenu.indexOfSelectedItem]) } else { chooseSource() }
    }
    @objc func mounted(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        // Let macOS finish presenting a newly mounted camera volume before checking DCIM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.refreshCards(activate: url)
        }
    }
    @objc func unmounted(_ note: Notification) {
        refreshCards()
        if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL,
           source.stringValue == url.path || source.stringValue.hasPrefix(url.path + "/") {
            token?.cancel(); invalidate(); status.stringValue = "Source card was removed. Reinsert it and scan again."
        }
    }
    func ejectVolume() -> URL? {
        guard !source.stringValue.isEmpty,
              let volume = try? URL(fileURLWithPath: source.stringValue).resourceValues(forKeys: [.volumeURLKey]).volume,
              volume.path.hasPrefix("/Volumes/"), !root.stringValue.hasPrefix(volume.path + "/"), root.stringValue != volume.path,
              cards.contains(volume) else { return nil }
        return volume
    }
    func updateEjectAvailability() {
        eject.isEnabled = !busy && ejectVolume() != nil
        if ejectVolume() == nil { eject.state = .off }
    }
    @objc func changePreset() {
        if presets.indexOfSelectedItem < patterns.count { template.stringValue = patterns[presets.indexOfSelectedItem] }
        invalidate(); updatePathPreview()
    }
    @objc func changeOptions() { datePicker.isEnabled = !busy && fallback.state == .on; invalidate(); updatePathPreview() }
    func controlTextDidChange(_ obj: Notification) {
        presets.selectItem(at: patterns.firstIndex(of: template.stringValue) ?? 5); invalidate(); updatePathPreview()
    }
    func updatePathPreview() {
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: datePicker.dateValue)
        let sample = CaptureDay(year: components.year!, month: components.month!, day: components.day!)
        do { pathPreview.stringValue = "Example:\n" + (try Importer.folder(template: template.stringValue, event: event.stringValue.isEmpty ? "Event Name" : event.stringValue, date: sample)); pathPreview.textColor = .secondaryLabelColor }
        catch { pathPreview.stringValue = error.localizedDescription; pathPreview.textColor = .systemRed }
        pathPreview.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    }
    func invalidate() { plan = nil; rows = []; thumbnails = [:]; table.reloadData(); importButton.isEnabled = false; summary.stringValue = "Scan to preview new photos and destination folders." }
    func currentSettings() -> Settings {
        var value = settings; value.destination = root.stringValue; value.folderTemplate = template.stringValue
        value.openInDxO = openDxO.state == .on; value.eject = eject.state == .on; return value
    }
    func setBusy(_ value: Bool) {
        busy = value; controlViews.forEach { $0.isEnabled = !value }; scan.isEnabled = !value
        importButton.isEnabled = !value && plan != nil && plan!.missingCount == 0
        cancelButton.isHidden = !value; cancelButton.isEnabled = true; datePicker.isEnabled = !value && fallback.state == .on
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil); updateEjectAvailability() }
        if !value && quitAfterWork { NSApp.terminate(nil) }
        if !value, let next = pendingCards.first { pendingCards.removeFirst(); if FileManager.default.fileExists(atPath: next.path) { setSource(next); showWindow() } }
    }
    func progress(_ text: String) { DispatchQueue.main.async { [weak self] in self?.status.stringValue = text } }
    @objc func scanSource() {
        guard !busy else { return }; window.makeFirstResponder(nil)
        guard !source.stringValue.isEmpty else { showError(ImportError("Choose a source card or folder first.")); return }
        settings = currentSettings()
        do { try settings.save() } catch { showError(error); return }
        let capturedSettings = settings, capturedSource = URL(fileURLWithPath: source.stringValue, isDirectory: true).standardizedFileURL
        let capturedEvent = event.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let c = calendar.dateComponents([.year, .month, .day], from: datePicker.dateValue)
        let chosenDate = fallback.state == .on ? CaptureDay(year: c.year!, month: c.month!, day: c.day!) : nil
        let cancellation = Cancellation(); token = cancellation; invalidate(); setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let value = try Importer.plan(source: capturedSource, settings: capturedSettings, event: capturedEvent, fallback: chosenDate,
                                              cancellation: cancellation, progress: self.progress)
                DispatchQueue.main.async {
                    self.plan = value; self.filterRows(); self.setBusy(false)
                    self.status.stringValue = value.missingCount > 0 ? "\(value.missingCount) new files have no capture date. Choose a fallback date and scan again." : "Preview ready. Only new files will be copied."
                }
            } catch { DispatchQueue.main.async { self.setBusy(false); self.showError(error) } }
        }
    }
    @objc func filterRows() {
        guard let value = plan else { return }
        rows = onlyNew.state == .on ? value.files.filter { $0.existing == nil } : value.files
        summary.stringValue = "\(value.newCount) new · \(value.files.count - value.newCount) duplicates · \(value.missingCount) missing dates · \(value.ignored) unsupported/links ignored"
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let file = rows[row]; let id = tableColumn?.identifier.rawValue ?? ""
        let text: String
        switch id {
        case "file": text = file.source.lastPathComponent
        case "date": text = file.date?.text ?? "Missing date"
        case "action": text = file.existing == nil ? "New" : (file.existing!.path.hasPrefix(plan!.source.path + "/") ? "Card duplicate" : "Already imported")
        default: text = file.existing.map { $0.path.replacingOccurrences(of: plan!.root.path + "/", with: "") } ?? file.folder ?? "Choose fallback date"
        }
        let field = label(text); field.lineBreakMode = .byTruncatingMiddle
        field.textColor = file.existing != nil ? .secondaryLabelColor : (file.date == nil ? .systemRed : .labelColor)
        let cell = NSTableCellView(); cell.textField = field; cell.addSubview(field); field.translatesAutoresizingMaskIntoConstraints = false
        var leading: CGFloat = 6
        if id == "file" {
            let imageView = NSImageView(); imageView.imageScaling = .scaleProportionallyUpOrDown; cell.addSubview(imageView); imageView.translatesAutoresizingMaskIntoConstraints = false
            if thumbnails[file.source.path] == nil, !pendingThumbnails.contains(file.source.path) {
                pendingThumbnails.insert(file.source.path)
                thumbnailQueue.async {
                    var thumbnail: CGImage?
                    if let imageSource = CGImageSourceCreateWithURL(file.source as CFURL, nil) {
                        thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: true, kCGImageSourceThumbnailMaxPixelSize: 64, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                    }
                    let image = thumbnail
                    DispatchQueue.main.async {
                        self.pendingThumbnails.remove(file.source.path)
                        guard self.plan?.files.contains(where: { $0.source == file.source }) == true else { return }
                        self.thumbnails[file.source.path] = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) } ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Photo")
                        self.table.reloadData()
                    }
                }
            }
            imageView.image = thumbnails[file.source.path] ?? NSImage(systemSymbolName: "photo", accessibilityDescription: "Photo")
            NSLayoutConstraint.activate([imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4), imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor), imageView.widthAnchor.constraint(equalToConstant: 32), imageView.heightAnchor.constraint(equalToConstant: 32)])
            leading = 42
        }
        field.toolTip = id == "file" ? file.source.path : text
        NSLayoutConstraint.activate([field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading), field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6), field.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
    @objc func startImport() {
        guard !busy, let value = plan, value.missingCount == 0 else { return }
        let volume = ejectVolume()
        let cancellation = Cancellation(); token = cancellation; setBusy(true)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result = try Importer.run(value, cancellation: cancellation, progress: self.progress)
                DispatchQueue.main.async {
                    self.invalidate()
                    self.status.stringValue = "\(result.copied) copied and verified · \(result.skipped) already imported."
                    self.finishImport(result, settings: value.settings, volume: volume)
                }
            } catch { DispatchQueue.main.async { self.invalidate(); self.setBusy(false); self.showError(error) } }
        }
    }
    func finishImport(_ result: ImportResult, settings: Settings, volume: URL?) {
        var detail = "\(result.copied) new files copied and verified.\n\(result.skipped) duplicates skipped.\n\nReport: \(result.receipt.path)"
        // Reveal every new folder; a rescan containing only duplicates opens no new folders.
        if settings.openInDxO && !result.folders.isEmpty {
            let app = URL(fileURLWithPath: settings.photoLab)
            if FileManager.default.fileExists(atPath: app.path) {
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                NSWorkspace.shared.open(result.folders, withApplicationAt: app, configuration: configuration) { _, error in
                    if let error = error { DispatchQueue.main.async { self.showError(ImportError("Import succeeded, but DxO could not open the folders: \(error.localizedDescription)")) } }
                }
            } else { detail += "\n\nDxO was not found. Choose its application in Settings." }
        }
        if settings.eject, let volume = volume {
            DispatchQueue.global(qos: .userInitiated).async {
                var ejectionError: Error?
                do { try self.token?.check(); try NSWorkspace.shared.unmountAndEjectDevice(at: volume) } catch { ejectionError = error }
                let finalError = ejectionError
                DispatchQueue.main.async {
                    self.setBusy(false)
                    self.showResult(result, detail: detail + (finalError.map { "\n\nCard could not be ejected: \($0.localizedDescription). Eject it in Finder." } ?? "\n\nCard safely ejected."))
                }
            }
        } else { setBusy(false); showResult(result, detail: detail) }
    }
    func showResult(_ result: ImportResult, detail: String) {
        let alert = NSAlert(); alert.messageText = "Import complete"; alert.informativeText = detail
        alert.addButton(withTitle: "Done"); alert.addButton(withTitle: "Show Report")
        if !result.folders.isEmpty { alert.addButton(withTitle: "Show in Finder") }
        let answer = alert.runModal()
        if answer == .alertSecondButtonReturn { NSWorkspace.shared.activateFileViewerSelecting([result.receipt]) }
        if answer == .alertThirdButtonReturn { NSWorkspace.shared.activateFileViewerSelecting(result.folders) }
    }
    @objc func cancelWork() { token?.cancel(); cancelButton.isEnabled = false; status.stringValue = "Cancelling safely…" }
    func showError(_ error: Error) {
        cancelButton.isEnabled = true; status.stringValue = error.localizedDescription
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Andermic Photo Importer"; alert.informativeText = error.localizedDescription; alert.runModal()
    }
    @objc func showSettings() {
        guard !busy else { return }
        let alert = NSAlert(); alert.messageText = "Local settings"; alert.informativeText = "ExifTool reads capture dates. Choose the installed DxO PhotoLab app for the optional handoff."
        let tool = NSTextField(string: settings.exiftool), dxo = NSTextField(string: settings.photoLab)
        let chooseTool = NSButton(title: "Choose ExifTool…", target: nil, action: nil), chooseDxO = NSButton(title: "Choose DxO…", target: nil, action: nil)
        let helper = SettingsChooser(tool: tool, dxo: dxo)
        chooseTool.target = helper; chooseTool.action = #selector(SettingsChooser.chooseTool)
        chooseDxO.target = helper; chooseDxO.action = #selector(SettingsChooser.chooseDxO)
        let view = stack([label("ExifTool executable"), tool, chooseTool, label("DxO PhotoLab application"), dxo, chooseDxO], spacing: 10)
        view.frame = NSRect(x: 0, y: 0, width: 440, height: 185); alert.accessoryView = view
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        if withExtendedLifetime(helper, { alert.runModal() }) == .alertFirstButtonReturn {
            settings = currentSettings(); settings.exiftool = tool.stringValue; settings.photoLab = dxo.stringValue
            do { try settings.save(); invalidate() } catch { showError(error) }
        }
    }
}

final class SettingsChooser: NSObject {
    let tool: NSTextField, dxo: NSTextField
    init(tool: NSTextField, dxo: NSTextField) { self.tool = tool; self.dxo = dxo }
    @objc func chooseTool() { let panel = NSOpenPanel(); panel.message = "Choose the exiftool executable"; panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin"); if panel.runModal() == .OK, let url = panel.url { tool.stringValue = url.path } }
    @objc func chooseDxO() { let panel = NSOpenPanel(); panel.message = "Choose DxO PhotoLab.app"; panel.directoryURL = URL(fileURLWithPath: "/Applications"); if panel.runModal() == .OK, let url = panel.url { dxo.stringValue = url.path } }
}
