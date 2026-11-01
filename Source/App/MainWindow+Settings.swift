import AppKit

/// Import Options: presets, destination, folder structure, completion and advanced settings.
extension MainWindowController {
    func loadInspector() {
        destinationPath.stringValue = (settings.destination as NSString).abbreviatingWithTildeInPath
        destinationPath.toolTip = settings.destination
        templateField.stringValue = settings.folderTemplate
        structurePopup.selectItem(at: FolderStructure.all.firstIndex { $0.template == settings.folderTemplate } ?? FolderStructure.all.count)
        openEditor.state = settings.openInDxO ? .on : .off
        ejectCheck.state = settings.eject ? .on : .off
        cardBehaviorPopup.selectItem(at: settings.cardInsertion == .showAndScan ? 0 : (settings.cardInsertion == .indicate ? 1 : 2))
        backgroundLaunch.state = settings.launchInBackground ? .on : .off
        otherCardPopup.selectItem(at: settings.otherCardCopies == .treatAsImported ? 1 : 0)
        rebuildPresetMenu()
    }

    func persist() { try? settings.save() }

    func rebuildPresetMenu() {
        presetPopup.removeAllItems()
        let current = settings.presets.firstIndex {
            $0.destination == settings.destination && $0.folderTemplate == settings.folderTemplate
                && $0.openInEditor == settings.openInDxO && $0.eject == settings.eject
        }
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
        if tag == -2 {
            savePreset()
        } else if tag <= -3 {
            settings.presets.remove(at: -3 - tag); persist()
        } else if settings.presets.indices.contains(tag) {
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
        settings.presets.append(
            ImportPreset(
                name: title, destination: settings.destination, folderTemplate: settings.folderTemplate,
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
    @objc func cardBehaviorChanged() { settings.cardInsertion = [CardInsertionBehavior.showAndScan, .indicate, .scanInBackground][cardBehaviorPopup.indexOfSelectedItem]; persist() }
    @objc func backgroundLaunchChanged() { settings.launchInBackground = backgroundLaunch.state == .on; persist() }
    @objc func otherCardChanged() {
        settings.otherCardCopies = otherCardPopup.indexOfSelectedItem == 1 ? .treatAsImported : .showAsNew; persist(); rescan()
    }
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
            do { _ = try Importer.folder(template: settings.folderTemplate, event: event, date: CaptureDay(year: 2026, month: 10, day: 4)) } catch { organizeError = error.localizedDescription }
        }
        refresh()
    }
}
