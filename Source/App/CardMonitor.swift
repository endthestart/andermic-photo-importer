import AppKit

/// Detects mounted local removable volumes that contain a DCIM folder while the app runs.
final class CardMonitor {
    private(set) var cards: [URL] = []
    /// Called on the main thread with the current card list and, when one was just mounted, that card.
    var onChange: (([URL], URL?) -> Void)?
    private var generation = 0
    var excludedPath: () -> String = { "" }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(mounted(_:)), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(unmounted(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        refresh()
    }

    @objc private func mounted(_ note: Notification) {
        guard let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
        // Let macOS finish presenting a newly mounted camera volume before checking DCIM.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh(inserted: url) }
    }
    @objc private func unmounted(_ note: Notification) { refresh() }

    func refresh(inserted: URL? = nil) {
        generation += 1
        let current = generation, destination = excludedPath()
        cards = []
        onChange?(cards, nil)
        // Mounted volumes can be sleeping, unavailable, or awaiting macOS permissions.
        // Probe each independently off the main thread so one stalled disk blocks nothing else.
        DispatchQueue.global(qos: .utility).async {
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            for volume in volumes where volume.path.hasPrefix("/Volumes/") && !destination.hasPrefix(volume.path + "/") && destination != volume.path {
                DispatchQueue.global(qos: .utility).async {
                    guard Self.isCard(volume) else { return }
                    DispatchQueue.main.async {
                        guard self.generation == current else { return }
                        if !self.cards.contains(volume) { self.cards.append(volume); self.cards.sort { $0.path < $1.path } }
                        self.onChange?(self.cards, inserted?.standardizedFileURL.path == volume.standardizedFileURL.path ? volume : nil)
                    }
                }
            }
        }
    }

    static func isCard(_ volume: URL) -> Bool {
        guard let values = try? volume.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey]),
              values.volumeIsLocal == true,
              values.volumeIsRemovable == true || (values.volumeIsEjectable == true && values.volumeIsInternal != true) else { return false }
        return ["DCIM", "dcim", "Dcim"].contains { name in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: volume.appendingPathComponent(name).path, isDirectory: &directory) && directory.boolValue
        }
    }
}
