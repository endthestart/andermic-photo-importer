import AppKit

/// Sources: cards, cameras, chosen folders and the sidebar list.
extension MainWindowController {
    func camerasChanged(_ list: [CameraImportSource], inserted: CameraImportSource?) {
        cameras = list
        // USB transfers need local space for every supported original. Keep them an
        // explicit selection even when mounted-card background scanning is enabled.
        if let inserted {
            newlyAvailable.insert(inserted.url)
            status("Camera “\(inserted.name)” is available. Select it to read its originals for preview.")
        }
        sidebar.reloadData(); selectSidebarRow(); refresh(); onStateChange?()
    }

    func cameraRemoved(_ camera: CameraImportSource) {
        newlyAvailable.remove(camera.url)
        guard source == camera.url else { return }
        scanToken?.cancel(); importToken?.cancel(); scanGeneration += 1
        if state == .scanning { state = .idle; progressBar.stopAnimation(nil) }
        thumbnails.cancelAll()
        source = nil; plan = nil; preliminary = nil; selection = []; cameraSnapshot = nil
        fallbackCheck.state = .off
        status("The camera was disconnected. Verified destination copies are kept. Reconnect it and scan again.")
    }

    var scanSource: URL? { cameraSnapshot?.directory ?? source }

    func cardsChanged(_ list: [URL], inserted: URL?) {
        cards = list
        newlyAvailable = newlyAvailable.filter { url in list.contains(url) || cameras.contains(where: { $0.url == url }) }
        sidebar.reloadData(); selectSidebarRow()
        if let card = inserted {
            if settings.cardInsertion != .indicate && state == .idle {
                if settings.cardInsertion == .showAndScan { showWindow(nil) }
                setSource(card, scan: true)
            } else {
                // Quiet mode, or work in progress: never switch away or interrupt.
                newlyAvailable.insert(card)
                sidebar.reloadData(); selectSidebarRow()
                status("Card “\(card.lastPathComponent)” is available. Select it to scan.")
            }
        } else if source == nil, state == .idle, let card = list.first, settings.cardInsertion != .indicate,
            Date().timeIntervalSince(launched) < 10
        {
            // Startup can scan an existing card while the window stays closed.
            // Later insertions follow the separate card setting.
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
        rows += [("CAMERAS", nil, "", true)]
        rows += cameras.isEmpty ? [("No cameras detected", nil, "camera", false)] : cameras.map { ($0.name, $0.url, "camera", false) }
        if let source, source.isFileURL, !cards.contains(source) { rows += [("FOLDER", nil, "", true), (source.lastPathComponent, source, "folder", false)] }
        return rows
    }
    func numberOfRows(in tableView: NSTableView) -> Int { sidebarRows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { sidebarRows[row].header }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { sidebarRows[row].url != nil && state != .importing }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = sidebarRows[row]
        if item.header {
            return Theme.sectionLabel(item.title)
        }
        let cell = NSTableCellView()
        let image = NSImageView(image: NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)!)
        image.contentTintColor = item.url == nil ? Theme.muted : Theme.accent
        image.setContentCompressionResistancePriority(.required, for: .horizontal)  // long names truncate; the icon stays
        let text = NSTextField(labelWithString: item.title); text.lineBreakMode = .byTruncatingMiddle
        text.textColor = item.url == nil ? Theme.muted : Theme.text
        var views: [NSView] = [image, text]
        if let url = item.url, newlyAvailable.contains(url) {
            let dot = NSImageView(image: NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "New card")!.withSymbolConfiguration(.init(pointSize: 7, weight: .regular))!)
            dot.contentTintColor = Theme.accent; views.append(dot)
        }
        if let url = item.url, url == source, state == .importing || state == .scanning {
            let spinner = NSProgressIndicator(); spinner.style = .spinning; spinner.controlSize = .small; spinner.startAnimation(nil); views.append(spinner)
        }
        let stack = NSStackView(views: views); stack.spacing = 6; stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack); cell.textField = text; cell.imageView = image
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2), stack.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.setAccessibilityLabel(item.title + (item.url.map { newlyAvailable.contains($0) ? ", new card" : "" } ?? ""))
        return cell
    }
    func selectSidebarRow() {
        if let index = sidebarRows.firstIndex(where: { $0.url != nil && $0.url == source }) { sidebar.selectRowIndexes([index], byExtendingSelection: false) } else { sidebar.deselectAll(nil) }
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
        let standardized = url.isFileURL ? url.standardizedFileURL : url
        scanToken?.cancel()
        thumbnails.cancelAll(); cameraSnapshot = nil
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
}
