#if UI_AUTOMATION
import AppKit

/// Test-only GUI driver, compiled only by scripts/ui-exercise.sh (never into shipped builds).
/// It operates the real controls: buttons and alert buttons via performClick, tiles via their
/// accessibility press action, popups via their actions. Screenshots are taken by the shell.
final class UIAutomation {
    let controller: MainWindowController
    var steps: [String]
    let log: URL
    var waitingUntil: Date?
    var waitingFor: URL?
    var retries = 0
    var fixtureInputMonitor: Any?
    /// The user's clipboard is restored when the exercise ends.
    let savedPasteboard: [[NSPasteboard.PasteboardType: Data]]

    init?(controller: MainWindowController) {
        guard let path = UserDefaults.standard.string(forKey: "AndermicUIScript"),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        self.controller = controller
        savedPasteboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in item.data(forType: type).map { (type, $0) } })
        }
        steps = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        log = URL(fileURLWithPath: path + ".log")
        try? Data().write(to: log)
        // Only this test app discards physical keystrokes while the driver owns its
        // responder chain. Other apps and every shipped build are unaffected.
        fixtureInputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { _ in nil }
        controller.window?.setContentSize(NSSize(width: 1300, height: 780)); controller.window?.center()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)   // keeps running inside modal alerts
    }

    func write(_ text: String) {
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        handle.seekToEndOfFile(); handle.write(Data((text + "\n").utf8)); try? handle.close()
    }

    var windows: [NSWindow] { ([NSApp.modalWindow].compactMap { $0 } + (controller.window?.attachedSheet.map { [$0] } ?? []) + [controller.window!]) }

    func restorePasteboard() {
        if let fixtureInputMonitor { NSEvent.removeMonitor(fixtureInputMonitor); self.fixtureInputMonitor = nil }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(savedPasteboard.map { saved in
            let item = NSPasteboardItem(); for (type, data) in saved { item.setData(data, forType: type) }; return item
        })
    }

    func menuItem(_ title: String, in menu: NSMenu? = NSApp.mainMenu) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if item.title == title { return item }
            if let found = menuItem(title, in: item.submenu) { return found }
        }
        return nil
    }

    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func button(_ prefix: String) -> NSButton? {
        for window in windows {
            guard let content = window.contentView else { continue }
            if let match = views(content.superview ?? content).compactMap({ $0 as? NSButton }).first(where: { $0.title.hasPrefix(prefix) && !$0.isHidden }) { return match }
        }
        return nil
    }

    /// Run editing assertions together: field setup and responder-chain commands must
    /// not be separated by desktop focus changes or keystrokes from unrelated work.
    func exerciseEditing(_ text: String) {
        guard NSApp.isActive, let editor = controller.eventField.currentEditor() as? NSTextView else {
            write("FAIL editing: event field is not active"); return
        }
        controller.eventField.stringValue = text
        editor.string = text
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.eventField))
        func invoke(_ title: String) {
            guard let item = menuItem(title), let action = item.action,
                  let handler = NSApp.target(forAction: action, to: item.target, from: item) else {
                write("FAIL editing menu \(title): no target"); return
            }
            if let validator = handler as? NSMenuItemValidation, !validator.validateMenuItem(item) {
                write("FAIL editing menu \(title): disabled"); return
            }
            write("ok editing \(title) -> \(type(of: handler as AnyObject))")
            NSApp.sendAction(action, to: item.target, from: item)
        }
        func check(_ condition: Bool, _ description: String) {
            write(condition ? "ok editing \(description)" : "FAIL editing \(description)")
        }
        invoke("Select All")
        check((editor.string as NSString).substring(with: editor.selectedRange()) == text, "selects field text")
        invoke("Copy")
        check(NSPasteboard.general.string(forType: .string) == text, "copies field text")
        invoke("Cut")
        check(editor.string.isEmpty, "cuts field text")
        invoke("Paste")
        check(editor.string == text, "pastes field text")
        invoke("Select All")
        invoke("Cut")
        check(editor.string.isEmpty, "clears fixture text")
    }

    func tick() {
        if let until = waitingUntil { if Date() < until { return }; waitingUntil = nil }
        if let file = waitingFor { if !FileManager.default.fileExists(atPath: file.path) { return }; waitingFor = nil }
        guard !steps.isEmpty else { return }
        // Dequeue first: actions can open modal alerts that run nested event loops (and ticks).
        let step = steps.removeFirst()
        let parts = step.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "wait": waitingUntil = Date().addingTimeInterval(Double(argument) ?? 1)
        case "waitIdle": if controller.state != .idle || NSApp.modalWindow != nil || controller.window?.attachedSheet != nil { steps.insert(step, at: 0); return }
        case "waitModal": if NSApp.modalWindow == nil && controller.window?.attachedSheet == nil { steps.insert(step, at: 0); return }
        case "open": controller.showWindow(nil); controller.setSource(URL(fileURLWithPath: argument), scan: true)
        case "toggle":
            let item = controller.collection.visibleItems().compactMap { $0 as? GroupTileItem }.first { $0.tile.entry?.name == argument }
            if let item { _ = item.tile.accessibilityPerformPress(); retries = 0 }
            else if retries < 8, let section = controller.sections.firstIndex(where: { $0.entries.contains { $0.name == argument } }),
                    let row = controller.sections[section].entries.firstIndex(where: { $0.name == argument }) {
                // Scroll the tile into view, as a user would, then press it on a later tick.
                retries += 1
                controller.collection.scrollToItems(at: [IndexPath(item: row, section: section)], scrollPosition: .centeredVertically)
                steps.insert(step, at: 0); return
            } else { write("FAIL toggle \(argument): tile not found"); retries = 0 }
        case "click", "check":   // check toggles a checkbox's state before sending its action, as a click would
            if let target = button(argument), target.isEnabled {
                write("ok \(step)")
                if parts[0] == "check" { target.state = target.state == .on ? .off : .on }
                _ = target.sendAction(target.action, to: target.target)
                return
            }
            else { write("FAIL click \(argument): \(button(argument) == nil ? "not found" : "disabled")") }
        case "popup":   // popup <date|type|structure> <index>
            let fields = argument.split(separator: " ")
            let popup = ["date": controller.datePopup, "type": controller.typePopup, "structure": controller.structurePopup, "card": controller.cardBehaviorPopup][String(fields[0])]!
            popup.selectItem(at: Int(fields[1])!); _ = popup.sendAction(popup.action, to: popup.target)
        case "setDate":
            controller.fallbackPicker.dateValue = ISO8601DateFormatter().date(from: argument + "T12:00:00Z")!
            _ = controller.fallbackPicker.sendAction(controller.fallbackPicker.action, to: controller.fallbackPicker.target)
        case "type":    // type event <text>
            let fields = argument.split(separator: " ", maxSplits: 1).map(String.init)
            let field = fields[0] == "event" ? controller.eventField : controller.templateField
            field.stringValue = fields.count > 1 ? fields[1] : ""
            controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        case "editing": exerciseEditing(argument)
        case "rescan": controller.rescan()
        case "menu":   // invoke a main-menu item exactly as AppKit does, including responder-chain routing
            guard let item = menuItem(argument), let action = item.action else { write("FAIL menu \(argument): not found"); break }
            // A user can only use the menu bar while the app is active with a key window.
            if !NSApp.isActive || NSApp.keyWindow == nil {
                controller.showWindow(nil)
                retries += 1
                if retries < 40 { steps.insert(step, at: 0); return }
                write("FAIL menu \(argument): the app could not become active")
            }
            retries = 0
            guard let handler = NSApp.target(forAction: action, to: item.target, from: item) else { write("FAIL menu \(argument): no target handles \(action)"); break }
            if let validator = handler as? NSMenuItemValidation, !validator.validateMenuItem(item) { write("FAIL menu \(argument): disabled"); break }
            write("ok \(step) -> \(type(of: handler as AnyObject))")
            NSApp.sendAction(action, to: item.target, from: item)
            return
        case "focus":
            // Menus route to the key window's responder chain, which exists only while the app is active.
            NSRunningApplication.current.activate(options: [])
            NSApp.activate(ignoringOtherApps: true)
            let responder: NSResponder = argument == "event" ? controller.eventField : controller.collection
            controller.showWindow(nil); controller.window?.makeFirstResponder(responder)
            if !NSApp.isActive { steps.insert(step, at: 0); retries += 1; if retries < 40 { return } else { write("FAIL focus: the app could not become active"); retries = 0 } }
            retries = 0
        case "tray":
            guard let tray = (NSApp.delegate as? AppDelegate)?.statusItem.menu,
                  let item = menuItem(argument, in: tray), let action = item.action else { write("FAIL tray item not found"); break }
            NSApp.sendAction(action, to: item.target, from: item)
        case "closeNotices": (NSApp.delegate as? AppDelegate)?.notices?.window?.performClose(nil)
        case "close": controller.window?.performClose(nil)
        case "card": controller.cardsChanged([URL(fileURLWithPath: argument)], inserted: URL(fileURLWithPath: argument))
        case "deminiaturize": controller.window?.deminiaturize(nil)
        case "expect":   // expect <key> <value>
            let fields = argument.split(separator: " ", maxSplits: 1).map(String.init)
            let expected = fields.count > 1 ? fields[1] : ""
            let editor = controller.eventField.currentEditor() as? NSTextView
            let actual: String
            switch fields[0] {
            // Never log clipboard contents: report only whether they match.
            case "pasteboard": actual = NSPasteboard.general.string(forType: .string) == expected ? expected : "<different clipboard contents>"
            case "event": actual = editor?.string ?? controller.eventField.stringValue
            case "selectedText": actual = editor.map { ($0.string as NSString).substring(with: $0.selectedRange()) } ?? ""
            case "miniaturized": actual = String(controller.window!.isMiniaturized)
            case "policy": actual = NSApp.activationPolicy() == .accessory ? "accessory" : "regular"
            case "tray": actual = String((NSApp.delegate as? AppDelegate)?.statusItem.button != nil)
            case "groups": actual = String(controller.plan?.groups.count ?? 0)
            case "backgroundLaunch": actual = String(controller.settings.launchInBackground)
            case "visible": actual = String(controller.window!.isVisible)
            case "selected": actual = String(controller.visibleSelection.count)
            case "fallbackVisible": actual = String(!controller.fallbackBox.isHidden)
            case "importSelected": actual = "\(controller.importSelectedButton.title)|\(controller.importSelectedButton.isEnabled)"
            case "status": actual = controller.plan.map { plan in plan.groups.first { $0.name == expected.split(separator: "=")[0].description }.map { "\($0.name)=\($0.status.rawValue)" } ?? "missing" } ?? "no plan"
            default: actual = "unknown key"
            }
            let context = ["event", "selectedText"].contains(fields[0])
                ? " (first responder \(String(describing: type(of: controller.window?.firstResponder as AnyObject))), field '\(controller.eventField.stringValue)', editor delegate \(String(describing: type(of: (editor?.delegate as AnyObject?) as AnyObject))))" : ""
            write(actual == expected ? "ok expect \(fields[0]) \(expected)" : "FAIL expect \(fields[0]): wanted '\(expected)', got '\(actual)'\(context)")
            return
        case "advanced": controller.showAdvanced()
        case "notices": (NSApp.delegate as? AppDelegate)?.showNotices()
        case "snapKey":   // the key window, such as Third-Party Notices
            write("SNAP \(argument) \(NSApp.keyWindow?.windowNumber ?? controller.window!.windowNumber) 0")
            waitingFor = log.deletingLastPathComponent().appendingPathComponent(argument + ".done")
        case "shell":
            write("SHELL \(argument)")
            waitingFor = log.deletingLastPathComponent().appendingPathComponent(argument + ".done")
        case "snap":
            let sheet = controller.window?.attachedSheet ?? NSApp.modalWindow
            write("SNAP \(argument) \(controller.window!.windowNumber) \(sheet?.windowNumber ?? 0)")
            waitingFor = log.deletingLastPathComponent().appendingPathComponent(argument + ".done")
        case "state":
            let plan = controller.plan
            write("STATE \(argument): groups=\(plan?.groups.count ?? 0) new=\(plan?.newGroups.count ?? 0) importable=\(plan?.importableNewGroups.count ?? 0) selected=\(controller.visibleSelection.count) imported=\(plan?.groups.filter { $0.status == .imported }.count ?? 0) importSelected='\(controller.importSelectedButton.title)' enabled=\(controller.importSelectedButton.isEnabled) importAll='\(controller.importAllButton.title)' enabled=\(controller.importAllButton.isEnabled) status='\(controller.statusLabel.stringValue)' selection='\(controller.selectionLabel.stringValue)'")
        case "alert": write("ALERT \(((NSApp.modalWindow ?? controller.window?.attachedSheet)?.contentView).map { views($0).compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " | ") } ?? "none")")
        case "quit": restorePasteboard(); write("DONE"); controller.quitAfterWork = false; NSApp.terminate(nil)
        default: write("FAIL unknown step \(step)")
        }
        write("ok \(step)")
    }
}
#endif
