import AppKit

/// Importing, results, errors and cancellation.
extension MainWindowController {
    @objc func importSelected() { startImport(visibleSelection) }
    @objc func importAllNew() { if let plan { startImport(plan.importableNewGroups) } }

    func startImport(_ groups: Set<Int>) {
        guard state == .idle, let plan, planIsCurrent, !groups.isEmpty else { return }
        guard plan.missingDates(in: groups) == 0 else {
            showError("Photos need a capture date", ImportError("Some selected photos have no capture date. Choose a fallback date in Import Options, or deselect them.")); return
        }
        window?.makeFirstResponder(nil)
        let volume = ejectableVolume()
        let token = Cancellation(); importToken = token
        state = .importing
        thumbnails.concurrency = 1  // leave card bandwidth for copying
        progressBar.isIndeterminate = false; progressBar.doubleValue = 0
        status("Preparing to import \(groups.count) photos…")
        refresh(); sidebar.reloadData(); selectSidebarRow(); onStateChange?()
        let snapshot = settings
        let retainedSnapshot = cameraSnapshot
        let importMetadataHelper = helper
        let cacheDirectory = verificationCacheDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self, retainedSnapshot] in
            defer { withExtendedLifetime(retainedSnapshot) {} }
            do {
                let result = try Importer.run(
                    plan, selection: groups, cancellation: token, verificationCache: DuplicateVerificationCache(directory: cacheDirectory), metadataHelper: importMetadataHelper,
                    progress: { update in
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
        if scanSource == plan.source {
            self.plan = plan.applying(result.outcomes)
            selection = self.plan!.newGroups.intersection(selection)
        } else {
            self.plan = nil; selection = []
        }
        thumbnails.concurrency = ThumbnailLoader.defaultConcurrency
        var detail = "\(result.copied) new \(result.copied == 1 ? "file" : "files") copied and verified from \(result.groups) \(result.groups == 1 ? "photo" : "photos")."
        if result.skipped > 0 { detail += " \(result.skipped) already present and verified." }
        if !result.notes.isEmpty { detail += "\n\n" + result.notes.joined(separator: "\n") }
        if snapshot.openInDxO && !result.folders.isEmpty {
            let app = URL(fileURLWithPath: snapshot.photoLab)
            if snapshot.editorAvailable {
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                NSWorkspace.shared.open(result.folders, withApplicationAt: app, configuration: configuration) { _, error in
                    if let error {
                        DispatchQueue.main.async {
                            self.showError(
                                "Couldn’t open the folders in \(snapshot.editorName)",
                                ImportError("Import succeeded, but \(snapshot.editorName) could not open the folders: \(error.localizedDescription)"))
                        }
                    }
                }
            } else {
                detail += "\n\n\(snapshot.editorName) was not found, so folders were not opened."
            }
        }
        status("Import complete: \(result.copied) copied and verified.")
        // Never eject a card that still holds new photos the user has not imported.
        let remaining = self.plan?.newGroups.count ?? plan.newGroups.count
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
                    self.showResult(
                        result, detail: detail + (failure.map { "\n\nThe card could not be ejected: \($0.localizedDescription) Eject it in Finder." } ?? "\n\nThe card was safely ejected."))
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
        state = .idle; thumbnails.concurrency = ThumbnailLoader.defaultConcurrency
        if let failure = error as? ImportFailure, scanSource == plan.source {
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
            if canRescan && answer == .alertSecondButtonReturn {
                self.startScan()
            } else if let failure, answer == (canRescan ? .alertThirdButtonReturn : .alertSecondButtonReturn) {
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
        if let window, window.isVisible, window.attachedSheet == nil { alert.beginSheetModal(for: window, completionHandler: completion) } else { completion(alert.runModal()) }
    }

    /// Only a detected camera card that does not hold the destination may be ejected.
    func ejectableVolume() -> URL? {
        guard let source, cards.contains(source),
            let volume = try? source.resourceValues(forKeys: [.volumeURLKey]).volume,
            volume.path.hasPrefix("/Volumes/"), !settings.destination.hasPrefix(volume.path + "/"), settings.destination != volume.path
        else { return nil }
        return volume
    }

    @objc func cancelWork() {
        switch state {
        case .scanning: scanToken?.cancel(); status("Stopping scan…")
        case .importing: importToken?.cancel(); cancelButton.isEnabled = false; status("Stopping safely after the current photo… verified copies are kept.")
        case .idle: break
        }
    }

    /// A warning sheet titled by what failed.
    func showError(_ title: String, _ error: Error) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = error.localizedDescription
        present(alert)
    }

    func windowDidBecomeKey(_ notification: Notification) { cancelButton.isEnabled = true }
}
