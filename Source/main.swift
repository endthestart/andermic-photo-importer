import AppKit

let application = NSApplication.shared
let controller = ImportWindow()
application.setActivationPolicy(.regular)
application.delegate = controller
application.run()
