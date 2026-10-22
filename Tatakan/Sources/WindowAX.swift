import AppKit
import ApplicationServices

// Tab Groups — thin layer over the Accessibility API and the window server.
// Coordinates here are global top-left (Accessibility / CGWindowList space).

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ el: AXUIElement, _ wid: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows macOS's own "allow Accessibility" prompt (only once per launch, macOS decides).
    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openPrivacyPane() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }

    static func wid(_ el: AXUIElement) -> CGWindowID? {
        var w: CGWindowID = 0
        return _AXUIElementGetWindow(el, &w) == .success && w != 0 ? w : nil
    }

    static func pid(_ el: AXUIElement) -> pid_t {
        var p: pid_t = 0; AXUIElementGetPid(el, &p); return p
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let pv: AXValue = attr(el, kAXPositionAttribute), let sv: AXValue = attr(el, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(pv, .cgPoint, &p); AXValueGetValue(sv, .cgSize, &s)
        return CGRect(origin: p, size: s)
    }

    static func setFrame(_ el: AXUIElement, _ r: CGRect) {
        // Some apps animate or snap when "enhanced UI" is on (VoiceOver mode); switch it off briefly.
        let app = AXUIElementCreateApplication(pid(el))
        let enhanced: Bool = attr(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        var p = r.origin, s = r.size
        if let sv = AXValueCreate(.cgSize, &s), let pv = AXValueCreate(.cgPoint, &p) {
            // size → position → size: lets a window cross into a smaller region or another display.
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
            AXUIElementSetAttributeValue(el, kAXPositionAttribute as CFString, pv)
            AXUIElementSetAttributeValue(el, kAXSizeAttribute as CFString, sv)
        }
        if enhanced { AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) }
    }

    static func isStandard(_ el: AXUIElement) -> Bool {
        let sub: String? = attr(el, kAXSubroleAttribute)
        return sub == (kAXStandardWindowSubrole as String)
    }

    static func raise(_ el: AXUIElement) {
        AXUIElementPerformAction(el, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(el, kAXMainAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid(el))?.activate()
    }

    static func focusedWindow() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        guard let app: AXUIElement = attr(sys, kAXFocusedApplicationAttribute) else { return nil }
        return attr(app, kAXFocusedWindowAttribute)
    }

    static func windows(of pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        return attr(app, kAXWindowsAttribute) ?? []
    }

}

/// A window as the window server sees it.
struct CGWin {
    let id: CGWindowID
    let pid: pid_t
    let frame: CGRect
    let onScreen: Bool
    let app: String

    /// Normal-layer windows, front to back.
    static func list(onScreenOnly: Bool = true) -> [CGWin] {
        let opts: CGWindowListOption = onScreenOnly ? [.optionOnScreenOnly, .excludeDesktopElements] : [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let r = CGRect(dictionaryRepresentation: b as CFDictionary) else { return nil }
            return CGWin(id: id, pid: pid, frame: r,
                         onScreen: (d[kCGWindowIsOnscreen as String] as? Bool) ?? false,
                         app: d[kCGWindowOwnerName as String] as? String ?? "")
        }
    }

    static func frame(of id: CGWindowID) -> CGRect? {
        // optionIncludingWindow = just this window (CGWindowListCreateDescriptionFromArray wants raw IDs, not NSNumbers).
        guard let arr = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let b = arr.first?[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(dictionaryRepresentation: b as CFDictionary)
    }

    static func top(at p: CGPoint) -> CGWin? {
        list().first { $0.frame.contains(p) && $0.frame.width > 40 && $0.frame.height > 40 }
    }
}

extension NSScreen {


    /// Visible frame (minus menu bar and Dock) in global top-left coordinates.
    var axVisibleFrame: CGRect { NSScreen.toAX(visibleFrame) }
    var axFrame: CGRect { NSScreen.toAX(frame) }

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func toAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func fromAX(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func axMouse() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: primaryHeight - m.y)
    }
    static func at(axPoint p: CGPoint) -> NSScreen? {
        screens.first { $0.axFrame.contains(p) }
    }
}
