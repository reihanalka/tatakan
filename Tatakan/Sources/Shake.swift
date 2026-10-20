import AppKit
import Carbon.HIToolbox

/// Detects "shake the pointer while dragging something" anywhere on screen.
final class ShakeDetector {
    var onShake: ((NSPoint) -> Void)?
    private var monitors: [Any] = []
    private var dragChangeCount = 0
    private var samples: [(t: TimeInterval, x: CGFloat)] = []
    private var firedThisDrag = false

    func start() {
        stop()
        let drag = NSPasteboard(name: .drag)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dragChangeCount = drag.changeCount
            self?.samples.removeAll()
            self?.firedThisDrag = false
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            self?.track(drag)
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            self?.samples.removeAll()
        } as Any)
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func track(_ drag: NSPasteboard) {
        let s = Settings.shared
        guard s.shakeEnabled, !firedThisDrag else { return }
        // Only when a real drag session started (drag pasteboard changed since mouse down).
        guard drag.changeCount != dragChangeCount else { return }
        if let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           s.excludedApps.contains(bid) { return }

        let now = ProcessInfo.processInfo.systemUptime
        let x = NSEvent.mouseLocation.x
        samples.append((now, x))
        samples.removeAll { now - $0.t > 0.6 }

        // Count direction reversals with meaningful travel.
        // sensitivity 0 (calm) … 1 (eager)
        let minTravel = 70 - 45 * s.shakeSensitivity      // px between turns
        let needed = s.shakeSensitivity > 0.66 ? 3 : 4
        var reversals = 0
        var dir: CGFloat = 0
        var anchor = samples.first?.x ?? x
        for p in samples.dropFirst() {
            let d = p.x - anchor
            if abs(d) < minTravel { continue }
            let nd: CGFloat = d > 0 ? 1 : -1
            if dir != 0 && nd != dir { reversals += 1 }
            dir = nd
            anchor = p.x
        }
        if reversals >= needed {
            firedThisDrag = true
            samples.removeAll()
            let p = NSEvent.mouseLocation
            DispatchQueue.main.async { self.onShake?(p) }
        }
    }
}

/// System-wide keyboard shortcut via Carbon (no Accessibility permission needed).
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false
    private let id: UInt32

    init(keyCode: UInt32, modifiers: UInt32, id: UInt32 = 1, handler: @escaping () -> Void) {
        self.id = id
        HotKey.handlers[id] = handler
        HotKey.installHandler()
        let hkID = EventHotKeyID(signature: OSType(0x54414D50), id: id) // 'TAMP'
        RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async { HotKey.handlers[hk.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
