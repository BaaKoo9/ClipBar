import AppKit

let app = NSApplication.shared
let appDelegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
