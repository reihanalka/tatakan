import AppKit

// Tatakan — a Dropover-style drag & drop shelf for macOS (personal build).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
