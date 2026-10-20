import AppKit

// Tatakan — a Dropover-style drag & drop shelf for macOS (personal build).
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
// SIGTERM (Tools/dev.sh, logout) → normal AppKit quit instead of an abrupt kill.
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { NSApp.terminate(nil) }
sigterm.resume()
app.run()
