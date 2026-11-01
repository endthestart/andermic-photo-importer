import AppKit

/// Refreshing the grid, the folder preview and the footer.
extension MainWindowController {
    func refresh() {
        guard window != nil else { return }
        rebuildDateFilter()
        sections = entries().map { (title: $0.0, detail: $0.1, entries: $0.2) }
        // Transition from preliminary to verified groups atomically. Layer-backed
        // tiles/headers own their text, so reused content cannot leave old glyphs.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0; context.allowsImplicitAnimation = false
            collection.collectionViewLayout?.invalidateLayout()
            collection.reloadData()
            collection.layoutSubtreeIfNeeded()
        }
        collection.needsDisplay = true
        let filtersEnabled = plan != nil && state == .idle
        for control in [datePopup, typePopup, showImported, sizeSlider] as [NSControl] { control.isEnabled = filtersEnabled || control === sizeSlider }

        titleLabel.stringValue = source?.lastPathComponent ?? "Import Photos"
        window?.title = source.map { "\($0.lastPathComponent) — Corvus" } ?? "Corvus"
        if let plan {
            let imported = plan.groups.filter { $0.status == .imported }.count
            let newGroups = plan.newGroups.count
            countsLabel.stringValue =
                "\(plan.groups.count) photos (\(plan.files.count) files) · \(newGroups) new · \(imported) already imported"
                + {
                    let other = plan.ignored + plan.orphanSidecars.count; return other == 0 ? "" : " · \(other) other \(other == 1 ? "file" : "files") not imported"
                }()
                + (plan.cachedGroups > 0 ? " · \(plan.cachedGroups) cached matches" : "")
        } else if let preliminary {
            countsLabel.stringValue = "\(preliminary.count) photos found · checking dates and duplicates…"
        } else {
            countsLabel.stringValue = source == nil ? "Insert a camera card or choose a folder to see its photos." : ""
        }
        countsLabel.toolTip = countsLabel.stringValue
        if source == nil {
            emptyState.stringValue = "Insert a camera card, or choose a folder of photos.\nNothing is copied until you choose an import button."
        } else if state == .scanning && sections.isEmpty {
            emptyState.stringValue = "Looking for photos…"
        } else if plan != nil && sections.isEmpty {
            emptyState.stringValue = "No photos match these filters."
        } else {
            emptyState.stringValue = ""
        }
        emptyState.isHidden = emptyState.stringValue.isEmpty

        // Inspector state
        let editing = state != .importing
        for control in [presetPopup, destinationButton, structurePopup, templateField, eventField, fallbackCheck, cardBehaviorPopup, otherCardPopup] as [NSControl] { control.isEnabled = editing }
        templateField.isEditable = editing
        fallbackPicker.isEnabled = editing && fallbackCheck.state == .on
        // Show the date control whenever any importable photo needs one (files placed beside an
        // already imported photo never do), or while a fallback is in effect.
        fallbackBox.isHidden = !needsFallback && fallbackCheck.state == .off
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
            previewLabel.stringValue = organizeError; previewLabel.textColor = Theme.bad; return
        }
        previewLabel.textColor = Theme.muted
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
            var counted = Set<String>()
            for file in plan.members(group) where plan.needsCopy(file) {
                let key: String
                if let beside = file.besideDirectory {
                    key = String(beside.path.dropFirst(plan.root.path.count + 1)) + " (beside imported photo)"
                } else {
                    key = group.folder ?? "⚠︎ needs a capture date"
                }
                if counted.insert(key).inserted { folders[key, default: (0, 0)].groups += 1 }
                folders[key, default: (0, 0)].files += 1
            }
        }
        if folders.isEmpty { previewLabel.stringValue = "Nothing new to import."; return }
        let lines = folders.keys.sorted().prefix(8).map { key in
            "\(key.hasPrefix("⚠︎") ? key : base + key.replacingOccurrences(of: " (beside", with: "/ (beside").appending(key.contains("(beside") ? "" : "/"))\n   \(folders[key]!.groups) \(folders[key]!.groups == 1 ? "photo" : "photos") · \(folders[key]!.files) \(folders[key]!.files == 1 ? "file" : "files")"
        }
        previewLabel.stringValue =
            (selection.isEmpty ? "All new photos:\n" : "Selected photos:\n") + lines.joined(separator: "\n")
            + (folders.count > 8 ? "\n…and \(folders.count - 8) more folders" : "")
    }

    var visibleSelection: Set<Int> { selection.intersection(visibleIDs) }
    var needsFallback: Bool { plan.map { plan in plan.groups.contains { $0.status != .imported && plan.missingDates(in: [$0.id]) > 0 } } ?? false }

    var planIsCurrent: Bool {
        guard let plan, source != nil, organizeError == nil else { return false }
        return plan.source == scanSource && plan.root.path == URL(fileURLWithPath: settings.destination).standardizedFileURL.path
            && plan.settings.folderTemplate == settings.folderTemplate && plan.fallback == fallback
            && (plan.event == event || !settings.folderTemplate.contains("{event}"))
    }

    func updateFooter() {
        let idle = state == .idle
        selectAllButton.isEnabled = idle && plan != nil && !visibleIDs.isEmpty
        selectAllNewButton.isEnabled = idle && plan != nil && !visibleIDs.filter { plan!.importableNewGroups.contains($0) }.isEmpty
        deselectAllButton.isEnabled = idle && !selection.isEmpty
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
        let fileCount = plan.fileCount(in: chosen)
        var text = chosen.isEmpty ? "No photos selected" : "\(chosen.count) selected · \(fileCount) \(fileCount == 1 ? "file" : "files") · \(bytes) to copy"
        if hidden > 0 { text += " · \(hidden) hidden by filters won’t be imported" }
        let missing = plan.missingDates(in: chosen)
        if missing > 0 { text += " · \(missing) selected files need a capture date" }
        selectionLabel.stringValue = text
        let undatedNotice = "no capture date and"
        if undated > 0 {
            status("\(undated) new \(undated == 1 ? "photo has" : "photos have") \(undatedNotice) \(undated == 1 ? "is" : "are") excluded until you choose a date in Import Options.")
        } else if statusLabel.stringValue.contains(undatedNotice) {
            status("")
        }
        updatePreview()
    }

    func status(_ text: String) { statusLabel.stringValue = text; statusLabel.toolTip = text }
}
