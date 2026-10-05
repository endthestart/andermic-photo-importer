import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    var controller: MainWindowController!
    var statusItem: NSStatusItem!
    let monitor = CardMonitor()
    var notices: NoticesWindow?
    #if UI_AUTOMATION
    var automation: UIAutomation?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MainWindowController(settings: Settings.load(), helper: MetadataHelper.bundled())
        createMenus()
        controller.onStateChange = { [weak self] in self?.updateStatusItem() }
        monitor.excludedPath = { [weak self] in self?.controller.settings.destination ?? "" }
        monitor.onChange = { [weak self] cards, inserted in self?.controller.cardsChanged(cards, inserted: inserted) }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(unmounted(_:)), name: NSWorkspace.didUnmountNotification, object: nil)
        monitor.start()
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        #if UI_AUTOMATION
        automation = UIAutomation(controller: controller)
        #endif
        if controller.helper == nil {
            controller.showError(ImportError("The app's built-in metadata reader is missing. Reinstall Andermic Photo Importer."))
        }
    }

    @objc func unmounted(_ note: Notification) {
        if let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { controller.volumeUnmounted(url) }
    }

    /// Folders opened with the app (Finder, Dock, or `open -a`) become the import source.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return }
        controller.showWindow(nil)
        controller.setSource(url, scan: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.state == .importing else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "Stop the import and quit?"
        alert.informativeText = "Verified copies stay in place and the card stays mounted. You can scan again later to import the rest."
        alert.addButton(withTitle: "Keep Importing"); alert.addButton(withTitle: "Stop and Quit")
        if alert.runModal() == .alertSecondButtonReturn { controller.quitAfterWork = true; controller.cancelWork() }
        return .terminateCancel
    }

    @objc func showWindow() { controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func showNotices() {
        if notices == nil { notices = NoticesWindow(helper: controller.helper) }
        notices?.showWindow(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showSettings() { showWindow(); controller.showAdvanced() }
    @objc func showAbout() {
        let versions = controller.helper?.readManifest()?.components.map { "\($0.name) \($0.version)" }.joined(separator: " and ") ?? "no metadata helper"
        let credits = NSAttributedString(string: "Copies only new photos into ordinary folders and verifies every file. Includes \(versions); see Third-Party Notices.",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func chooseSource() { showWindow(); controller.chooseSource() }
    @objc func chooseDestination() { showWindow(); controller.chooseDestination() }
    @objc func rescan() { controller.rescan() }
    @objc func importSelected() { controller.importSelected() }
    @objc func importAllNew() { controller.importAllNew() }
    @objc func selectAllNew() { controller.selectAllNew(nil) }
    @objc func deselectAll() { controller.deselectAll(nil) }
    @objc func toggleImported() { controller.showImported.state = controller.showImported.state == .on ? .off : .on; controller.filtersChanged() }
    @objc func zoomIn() { controller.zoom(by: 30) }
    @objc func zoomOut() { controller.zoom(by: -30) }
    @objc func toggleInspector() { controller.toggleInspector() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let idle = controller.state == .idle
        switch item.action {
        case #selector(rescan): return controller.source != nil && controller.state != .importing
        case #selector(importSelected): return controller.importSelectedButton.isEnabled
        case #selector(importAllNew): return controller.importAllButton.isEnabled
        case #selector(chooseSource), #selector(chooseDestination): return controller.state != .importing
        case #selector(selectAllNew), #selector(deselectAll): return idle && controller.plan != nil
        case #selector(toggleImported): item.state = controller.showImported.state; return controller.plan != nil
        default: return true
        }
    }

    func createMenus() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let menu = NSMenu(title: title); items.forEach(menu.addItem)
            let item = NSMenuItem(); item.submenu = menu; main.addItem(item); return menu
        }
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.keyEquivalentModifierMask = modifiers
            item.target = target ?? self; return item
        }
        let name = "Andermic Photo Importer"
        _ = submenu(name, [
            item("About \(name)", #selector(showAbout)),
            item("Third-Party Notices…", #selector(showNotices)),
            .separator(),
            item("Settings…", #selector(showSettings), ","),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
        _ = submenu("File", [
            item("Choose Source Folder…", #selector(chooseSource), "o"),
            item("Choose Destination…", #selector(chooseDestination), "o", [.command, .shift]),
            .separator(),
            item("Scan Again", #selector(rescan), "r"),
            item("Import Selected", #selector(importSelected), "i"),
            item("Import All New", #selector(importAllNew), "i", [.command, .shift]),
            .separator(),
            item("Close Window", #selector(NSWindow.performClose(_:)), "w", target: nil),
        ])
        let edit = submenu("Edit", [
            item("Undo", Selector(("undo:")), "z", target: nil), item("Redo", Selector(("redo:")), "z", [.command, .shift], target: nil),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", target: nil), item("Copy", #selector(NSText.copy(_:)), "c", target: nil),
            item("Paste", #selector(NSText.paste(_:)), "v", target: nil),
            // Text fields handle ⌘A themselves; elsewhere the window selects all new photos.
            item("Select All", #selector(NSResponder.selectAll(_:)), "a", target: nil),
            .separator(),
            item("Select All New Photos", #selector(selectAllNew), "a", [.command, .option]),
            item("Deselect All Photos", #selector(deselectAll), "a", [.command, .shift]),
        ])
        _ = edit
        _ = submenu("View", [
            item("Show Already Imported", #selector(toggleImported), "e", [.command, .shift]),
            .separator(),
            item("Larger Thumbnails", #selector(zoomIn), "+"),
            item("Smaller Thumbnails", #selector(zoomOut), "-"),
            .separator(),
            item("Toggle Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control], target: nil),
            item("Toggle Import Options", #selector(toggleInspector), "i", [.command, .option]),
        ])
        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil),
            item("Zoom", #selector(NSWindow.performZoom(_:)), target: nil),
            .separator(),
            item("Andermic Photo Importer", #selector(showWindow), "0"),
        ])
        NSApp.windowsMenu = window
        let help = submenu("Help", [item("Third-Party Notices", #selector(showNotices))])
        NSApp.helpMenu = help
        NSApp.mainMenu = main

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let tray = NSMenu()
        tray.addItem(item("Show \(name)", #selector(showWindow)))
        tray.addItem(.separator())
        tray.addItem(item("Quit", #selector(NSApplication.terminate(_:)), target: NSApp))
        statusItem.menu = tray
        updateStatusItem()
    }

    /// The menu bar icon quietly indicates a newly available card without opening the window.
    func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let available = !controller.newlyAvailable.isEmpty
        let symbol = controller.state == .importing ? "arrow.down.circle" : (available ? "sdcard.fill" : "camera.badge.ellipsis")
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Andermic Photo Importer")
        button.toolTip = available ? "Card available: " + controller.newlyAvailable.map(\.lastPathComponent).sorted().joined(separator: ", ")
            : (controller.state == .importing ? "Importing photos…" : "Andermic Photo Importer")
    }
}
