// First-click regression test with the REAL cursor: hover the notch open, click the Tray tab ONCE,
// capture; then click Home once, capture. Both captures must show the clicked tab selected.
//   swift Tools/clicktest.swift <outdir>
import AppKit
import CoreGraphics

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/clicktest"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
let mid = screen.frame.midX
let start = CGEvent(source: nil)?.location ?? .zero
func post(_ t: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}
func click(_ p: CGPoint) { post(.mouseMoved, p); usleep(120_000); post(.leftMouseDown, p); usleep(60_000); post(.leftMouseUp, p) }
func cap(_ name: String) {
    let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    t.arguments = ["-x", "-R\(Int(mid - 440)),0,880,300", "\(out)/\(name).png"]; try? t.run(); t.waitUntilExit()
}
// Make another app frontmost first, like real use (Finder).
NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")); usleep(600_000)
for y in stride(from: 200.0, through: 0.0, by: -40.0) { post(.mouseMoved, CGPoint(x: mid + 20, y: y)); usleep(16_000) }
usleep(900_000)
click(CGPoint(x: mid - 255, y: 19))      // Tray tab
usleep(700_000); cap("1-tray")
click(CGPoint(x: mid - 305, y: 19))      // Home tab
usleep(700_000); cap("2-home")
post(.mouseMoved, CGPoint(x: mid, y: 700)); usleep(900_000)
// reopen and click once more (the "only works once" case)
for y in stride(from: 200.0, through: 0.0, by: -40.0) { post(.mouseMoved, CGPoint(x: mid + 20, y: y)); usleep(16_000) }
usleep(900_000)
click(CGPoint(x: mid - 255, y: 19))
usleep(700_000); cap("3-reopen-tray")
post(.mouseMoved, start)
print("ok", out)
