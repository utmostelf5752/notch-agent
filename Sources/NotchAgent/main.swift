import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// Accessory: no dock icon, no menu bar entry. Quit with Cmd+Q while the panel
// is open, or `pkill NotchAgent`.
app.setActivationPolicy(.accessory)
app.run()
