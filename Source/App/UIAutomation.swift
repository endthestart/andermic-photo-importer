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

    init?(controller: MainWindowController) {
        guard let path = UserDefaults.standard.string(forKey: "AndermicUIScript"),
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        self.controller = controller
        steps = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        log = URL(fileURLWithPath: path + ".log")
        try? Data().write(to: log)
        controller.window?.setContentSize(NSSize(width: 1300, height: 780)); controller.window?.center()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)   // keeps running inside modal alerts
    }

    func write(_ text: String) {
        guard let handle = try? FileHandle(forWritingTo: log) else { return }
        handle.seekToEndOfFile(); handle.write(Data((text + "\n").utf8)); try? handle.close()
    }

    var windows: [NSWindow] { ([NSApp.modalWindow].compactMap { $0 } + (controller.window?.attachedSheet.map { [$0] } ?? []) + [controller.window!]) }

    func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    func button(_ prefix: String) -> NSButton? {
        for window in windows {
            guard let content = window.contentView else { continue }
            if let match = views(content.superview ?? content).compactMap({ $0 as? NSButton }).first(where: { $0.title.hasPrefix(prefix) && !$0.isHidden }) { return match }
        }
        return nil
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
        case "open": controller.setSource(URL(fileURLWithPath: argument), scan: true)
        case "toggle":
            let item = controller.collection.visibleItems().compactMap { $0 as? GroupTileItem }.first { $0.tile.entry?.name == argument }
            if let item { _ = item.tile.accessibilityPerformPress() } else { write("FAIL toggle \(argument): tile not visible") }
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
        case "rescan": controller.rescan()
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
        case "quit": write("DONE"); controller.quitAfterWork = false; NSApp.terminate(nil)
        default: write("FAIL unknown step \(step)")
        }
        write("ok \(step)")
    }
}
#endif
