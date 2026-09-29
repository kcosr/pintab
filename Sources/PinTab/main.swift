import AppKit

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
// Menu-bar utility: no Dock icon. LSUIElement in Info.plist does the same for the bundled app;
// this also covers running the bare executable during development.
application.setActivationPolicy(.accessory)
application.run()
