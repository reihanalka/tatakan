// Hover regression test: push the pointer against the very top edge above the notch (y == 0 in CG
// coordinates, i.e. NSScreen maxY) and report whether the Nook window grew. Moves the real cursor.
//   swift Tools/hovertest.swift
import AppKit
import CoreGraphics

// Writes <png> (pointer at the top edge, Nook should be open) and <png>-after (pointer away, closed).
let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
let midX = screen.frame.midX
let start = CGEvent(source: nil)?.location ?? .zero
func move(_ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
// approach from below in a few steps, then slam to y = 0 (top edge)
for y in stride(from: 200.0, through: 0.0, by: -40.0) { move(CGPoint(x: midX + 30, y: y)); usleep(16_000) }
move(CGPoint(x: midX + 30, y: 0))
usleep(700_000)
let png = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/hover.png"
let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t.arguments = ["-x", png]
try? t.run(); t.waitUntilExit()
move(CGPoint(x: midX, y: 600)); usleep(900_000)
let t2 = Process(); t2.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture"); t2.arguments = ["-x", png.replacingOccurrences(of: ".png", with: "-after.png")]
try? t2.run(); t2.waitUntilExit()
move(start)
print("captured", png)
