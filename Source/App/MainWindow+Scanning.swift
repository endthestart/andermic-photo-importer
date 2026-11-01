import AppKit

/// Scanning a source into a preview plan.
extension MainWindowController {
    @objc func rescan() { if source != nil, state != .importing { startScan() } }

    @objc func fullVerification() {
        if source != nil, state != .importing { startScan(reuseCachedHashes: false) }
    }

    func startScan(reuseCachedHashes: Bool = true) {
        guard let source, state != .importing else { return }
        guard let helper else { showError("Metadata reader missing", ImportError("The app's built-in metadata reader is missing. Reinstall Corvus.")); return }
        scanToken?.cancel()
        scanGeneration += 1
        let generation = scanGeneration, token = Cancellation()
        scanToken = token
        thumbnails.cancelAll()
        cameraSnapshot = nil
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
        let scanSettings = snapshot
        let cacheDirectory = verificationCacheDirectory
        refresh(); onStateChange?()
        let scan: (CameraSnapshot?) -> Void = { [weak self] snapshot in
            guard let self, generation == self.scanGeneration, !token.isCancelled else { return }
            self.cameraSnapshot = snapshot
            let input = snapshot?.directory ?? source
            DispatchQueue.global(qos: .userInitiated).async { [weak self, snapshot] in
                do {
                    var value = try Importer.plan(
                        source: input, settings: scanSettings, event: scanSettings.folderTemplate.contains("{event}") ? event : "", fallback: fallback,
                        helper: helper, cancellation: token,
                        verificationCache: DuplicateVerificationCache(directory: cacheDirectory), reuseCachedHashes: reuseCachedHashes,
                        transferred: snapshot?.transferred ?? [:],
                        progress: { update in DispatchQueue.main.async { self?.scanProgress(update, generation) } },
                        discovered: { groups in DispatchQueue.main.async { self?.discovered(groups, generation) } })
                    if let snapshot {
                        value.sourceDescription = source.absoluteString
                        value.sourceFileDescriptions = snapshot.origins
                    }
                    DispatchQueue.main.async { self?.scanFinished(value, generation) }
                } catch {
                    DispatchQueue.main.async { self?.scanFailed(error, generation, token) }
                }
            }
        }
        if let camera = cameras.first(where: { $0.url == source }) {
            camera.prepare(
                cancellation: token,
                progress: { [weak self] update in
                    DispatchQueue.main.async { self?.scanProgress(update, generation) }
                },
                completion: { [weak self] result in
                    switch result {
                    case .success(let snapshot): scan(snapshot)
                    case .failure(let error): self?.scanFailed(error, generation, token)
                    }
                })
        } else {
            scan(nil)
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
        guard generation == scanGeneration, value.source == scanSource, value.root.path == URL(fileURLWithPath: settings.destination).standardizedFileURL.path else { return }
        plan = value; preliminary = nil
        state = .idle; progressBar.stopAnimation(nil)
        organizeError = nil
        do { plan = try value.organized(template: settings.folderTemplate, event: event, fallback: fallback) } catch { organizeError = error.localizedDescription }
        selection = plan?.importableNewGroups ?? []
        sidebar.reloadData(); selectSidebarRow()
        let elapsed = Date().timeIntervalSince(scanStarted)
        let reads = value.scanReads
        var summary = String(
            format: "Scanned in %.1f s · %@ read to check %@ of photos.", elapsed,
            ByteCountFormatter.string(fromByteCount: Int64(reads.total), countStyle: .file),
            ByteCountFormatter.string(fromByteCount: Int64(value.files.reduce(0) { $0 + $1.size }), countStyle: .file))
        if reads.cachedCaptureDates > 0 { summary += " \(reads.cachedCaptureDates) cached capture dates." }
        if value.cachedGroups > 0 {
            summary += " \(value.cachedGroups) cached matches. Import checks attributes and samples for unselected previous imports; Full Verification rereads complete contents."
        }
        if value.otherCardGroups > 0 { summary += " \(value.otherCardGroups) imported from the camera's other card." }
        status(summary)
        refresh()
        gridScroll.contentView.scroll(to: .zero)
        gridScroll.reflectScrolledClipView(gridScroll.contentView)
        onStateChange?()
    }
    func scanFailed(_ error: Error, _ generation: Int, _ token: Cancellation) {
        guard generation == scanGeneration else { return }
        state = .idle; progressBar.stopAnimation(nil); preliminary = nil
        refresh(); sidebar.reloadData(); selectSidebarRow(); onStateChange?()
        if token.isCancelled { status("Scan stopped."); return }
        status(error.localizedDescription)
        showError("Scan did not finish", error)
    }
}
