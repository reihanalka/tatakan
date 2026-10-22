import AppKit
import Carbon.HIToolbox

// Tab Groups — any windows, any apps, one frame with a strip of tabs.
// Drag a window onto the middle of another and hold for half a second: they share one frame under a strip
// of tabs, whatever their apps. Inactive tabs wait just off-screen. Drag a tab out of the strip to tear it off.
// Off by default; needs Accessibility (only asked for when switched on).

final class TabGroup {
    var tabs: [CGWindowID]
    var active: CGWindowID
    var frame: CGRect              // strip + content, global top-left coordinates

    init(tabs: [CGWindowID], active: CGWindowID, frame: CGRect) { self.tabs = tabs; self.active = active; self.frame = frame }

    var isGroup: Bool { tabs.count > 1 }

    func add(_ w: CGWindowID) {
        guard !tabs.contains(w) else { return }
        tabs.insert(w, at: (tabs.firstIndex(of: active) ?? tabs.count - 1) + 1)
        active = w
    }

    func remove(_ w: CGWindowID) {
        guard let i = tabs.firstIndex(of: w) else { return }
        tabs.remove(at: i)
        if active == w, !tabs.isEmpty { active = tabs[min(i, tabs.count - 1)] }
    }

    func move(_ w: CGWindowID, to index: Int) {
        guard let i = tabs.firstIndex(of: w) else { return }
        tabs.remove(at: i)
        tabs.insert(w, at: max(0, min(index, tabs.count)))
    }

    struct Saved: Codable { var t: [UInt32]; var a: UInt32; var f: [Double] }
    var saved: Saved { Saved(t: tabs, a: active, f: [frame.minX, frame.minY, frame.width, frame.height].map(Double.init)) }
}

final class TabGroupController {
    static let shared = TabGroupController()
    static let stripHeight: CGFloat = 30
    static let holdTime: TimeInterval = 0.5

    private(set) var running = false
    private(set) var groups: [TabGroup] = []
    private var axCache: [CGWindowID: AXUIElement] = [:]
    private var monitors: [Any] = []
    private var timers: [Timer] = []
    private var observers: [NSObjectProtocol] = []
    private var hotKeys: [HotKey] = []
    private var trustTimer: Timer?
    private let overlay = DropOverlay()
    private var strips: [TabStripPanel] = []
    private var lastStripRefresh: TimeInterval = 0

    // Drag state
    private var drag: (id: CGWindowID, pid: pid_t, start: CGRect, moving: Bool, resizing: Bool, eligible: Bool?)?
    private var target: Target?
    private var dwell: (id: CGWindowID, anchor: CGPoint, timer: Timer, fired: Bool)?
    private var draggingID: CGWindowID?

    enum Target { case hover(CGWindowID), tab(CGWindowID) }

    // MARK: Lifecycle

    func sync() {
        if Settings.shared.tabGroupsEnabled {
            if AX.trusted { start() } else { waitForTrust() }
        } else { stop() }
    }

    private func waitForTrust() {
        AX.requestTrust()
        trustTimer?.invalidate()
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard Settings.shared.tabGroupsEnabled else { t.invalidate(); return }
            if AX.trusted { t.invalidate(); self?.start() }
        }
    }

    private func start() {
        guard !running else { return }
        running = true
        load()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] e in self?.mouse(e) } as Any)
        timers.append(Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.reconcile() })
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                  NSWorkspace.didUnhideApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                  NSWorkspace.activeSpaceDidChangeNotification] {
            observers.append(ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self?.reconcile() }
            })
        }
        let cm = UInt32(controlKey | optionKey), cms = UInt32(controlKey | optionKey | shiftKey)
        hotKeys.append(HotKey(keyCode: UInt32(kVK_Tab), modifiers: cm, id: 40) { [weak self] in self?.cycle(1) })
        hotKeys.append(HotKey(keyCode: UInt32(kVK_Tab), modifiers: cms, id: 41) { [weak self] in self?.cycle(-1) })
        groups.forEach(apply)
    }

    func stop() {
        trustTimer?.invalidate(); trustTimer = nil
        guard running else { return }
        save()
        unpark()
        running = false
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors.removeAll()
        timers.forEach { $0.invalidate() }; timers.removeAll()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers.removeAll()
        hotKeys.removeAll()
        overlay.hide()
        strips.forEach { $0.orderOut(nil) }; strips.removeAll()
    }

    /// Quit: groups are saved; hidden tabs come back on screen, behind the visible one.
    func willTerminate() { if running { save(); unpark() } }

    private func unpark() {
        for g in groups {
            let f = contentFrame(g)
            for id in g.tabs where id != g.active { if let el = element(id) { AX.setFrame(el, f) } }
        }
    }

    // MARK: Persistence

    private func save() {
        let list = groups.filter(\.isGroup).map(\.saved)
        UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "tabGroups")
    }

    private func load() {
        groups.removeAll()
        guard let d = UserDefaults.standard.data(forKey: "tabGroups"),
              let list = try? JSONDecoder().decode([TabGroup.Saved].self, from: d) else { return }
        let alive = Set(CGWin.list(onScreenOnly: false).map(\.id))
        for s in list where s.f.count == 4 {
            let g = TabGroup(tabs: s.t.filter(alive.contains), active: s.a,
                             frame: CGRect(x: s.f[0], y: s.f[1], width: s.f[2], height: s.f[3]))
            if !g.tabs.contains(g.active), let first = g.tabs.first { g.active = first }
            if g.isGroup { groups.append(g) }
        }
    }

    // MARK: Helpers

    func group(of wid: CGWindowID) -> TabGroup? { groups.first { $0.tabs.contains(wid) } }

    func element(_ wid: CGWindowID, pid: pid_t? = nil) -> AXUIElement? {
        if let e = axCache[wid], AX.wid(e) == wid { return e }
        let pids: [pid_t] = pid.map { [$0] } ?? CGWin.list(onScreenOnly: false).filter { $0.id == wid }.map(\.pid)
        for p in pids { for w in AX.windows(of: p) { if let id = AX.wid(w) { axCache[id] = w } } }
        return axCache[wid]
    }

    private func eligible(_ wid: CGWindowID, pid: pid_t) -> Bool {
        if let bid = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           Settings.shared.tabGroupsIgnored.contains(bid) || bid == Bundle.main.bundleIdentifier { return false }
        guard let el = element(wid, pid: pid) else { return false }
        return AX.isStandard(el)
    }

    func contentFrame(_ g: TabGroup) -> CGRect {
        CGRect(x: g.frame.minX, y: g.frame.minY + Self.stripHeight, width: g.frame.width, height: g.frame.height - Self.stripHeight)
    }

    private func groupFrame(content f: CGRect) -> CGRect {
        CGRect(x: f.minX, y: f.minY - Self.stripHeight, width: f.width, height: f.height + Self.stripHeight)
    }

    /// Just past the screen's bottom-right corner (or bottom-left if another display sits to the right).
    private func parkFrame(size: CGSize, on scr: NSScreen) -> CGRect {
        let s = scr.axFrame
        var x = s.maxX - 1
        if NSScreen.screens.contains(where: { $0 !== scr && $0.axFrame.contains(CGPoint(x: s.maxX + 2, y: s.maxY - 1)) }) {
            x = s.minX - size.width + 1
        }
        return CGRect(x: x, y: s.maxY - 1, width: size.width, height: size.height)
    }

    private func screen(of r: CGRect) -> NSScreen {
        NSScreen.at(axPoint: CGPoint(x: r.midX, y: r.minY + 10)) ?? NSScreen.screens[0]
    }

    /// Keep a rect fully inside a screen's visible area.
    private func onScreen(_ r: CGRect) -> CGRect {
        let v = screen(of: r).axVisibleFrame.insetBy(dx: 6, dy: 6)
        let w = min(r.width, v.width), h = min(r.height, v.height)
        return CGRect(x: min(max(r.minX, v.minX), v.maxX - w), y: min(max(r.minY, v.minY), v.maxY - h), width: w, height: h).integral
    }

    /// Show the active tab in the group's frame, park the rest, redraw the strip.
    func apply(_ g: TabGroup) {
        guard let el = element(g.active) else { return }
        let content = contentFrame(g)
        if AX.frame(el)?.integral != content.integral { AX.setFrame(el, content) }
        let scr = screen(of: g.frame)
        for m in g.tabs where m != g.active {
            guard let mel = element(m) else { continue }
            let park = parkFrame(size: content.size, on: scr)
            if AX.frame(mel)?.integral != park.integral { AX.setFrame(mel, park) }
        }
        refreshStrips()
        save()
    }

    // MARK: Reconcile (closed, minimized, switched to from the Dock / ⌘Tab)

    private func reconcile() {
        guard running, draggingID == nil, drag?.moving != true else { return }
        let all = Dictionary(CGWin.list(onScreenOnly: false).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for g in groups {
            for m in g.tabs where all[m] == nil { g.remove(m); axCache[m] = nil }
            if !g.isGroup { dissolve(g); continue }
            if all[g.active]?.onScreen != true,
               let other = g.tabs.first(where: { $0 != g.active && all[$0]?.onScreen == true }) {
                g.active = other; apply(g)                     // active tab minimized: the next one shows
            }
        }
        if let el = AX.focusedWindow(), let f = AX.wid(el), let g = group(of: f), g.active != f {
            g.active = f; apply(g)
        } else {
            refreshStrips()
        }
    }

    // MARK: Mouse

    private func mouse(_ e: NSEvent) {
        let p = NSScreen.axMouse()
        switch e.type {
        case .leftMouseDown:
            target = nil
            drag = CGWin.top(at: p).map { ($0.id, $0.pid, $0.frame, false, false, nil) }
        case .leftMouseDragged:
            guard var d = drag, let f = CGWin.frame(of: d.id) else { return }
            if !d.moving && !d.resizing {
                if f.size != d.start.size { d.resizing = true }
                else if hypot(f.minX - d.start.minX, f.minY - d.start.minY) > 3 { d.moving = true }
            }
            if d.moving && d.eligible == nil { d.eligible = eligible(d.id, pid: d.pid) }
            drag = d
            if d.moving, let g = group(of: d.id), g.active == d.id {
                g.frame = groupFrame(content: f)              // the strip follows its window
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastStripRefresh > 1.0 / 30 { lastStripRefresh = now; refreshStrips() }
            }
            if d.moving && d.eligible == true { draggingID = d.id; dragMoved(d.id, at: p) }
        case .leftMouseUp:
            overlay.hide()
            cancelDwell()
            draggingID = nil
            defer { drag = nil; target = nil }
            guard let d = drag else { return }
            if d.moving, d.eligible == true { drop(d.id, at: p, torn: false) }
            else if d.resizing, let g = group(of: d.id), g.active == d.id, let f = CGWin.frame(of: d.id) {
                g.frame = groupFrame(content: f); apply(g)
            }
        default: break
        }
    }

    /// The front-most other window whose middle is under the pointer.
    private func windowBelow(_ p: CGPoint, excluding wid: CGWindowID) -> CGWindowID? {
        guard let w = CGWin.list().first(where: { $0.id != wid && $0.frame.contains(p) && $0.frame.width > 120 && $0.frame.height > 90 }),
              eligible(w.id, pid: w.pid) else { return nil }
        var f = w.frame
        if let g = group(of: w.id) { f = g.frame }
        return f.insetBy(dx: f.width * 0.22, dy: f.height * 0.22).contains(p) ? w.id : nil
    }

    private func dragMoved(_ wid: CGWindowID, at p: CGPoint) {
        // The hold only counts while the pointer rests; moving more than a few points restarts it.
        if let d = dwell, !d.fired, hypot(p.x - d.anchor.x, p.y - d.anchor.y) > 8 { cancelDwell() }
        var t: Target?
        if let id = windowBelow(p, excluding: wid), group(of: id)?.tabs.contains(wid) != true {
            if let d = dwell, d.id == id { t = d.fired ? .tab(id) : .hover(id) } else { startDwell(id, at: p); t = .hover(id) }
        } else {
            cancelDwell()
        }
        target = t
        guard let t else { overlay.hide(); return }
        switch t {
        case .hover(let id), .tab(let id):
            let r = group(of: id)?.frame ?? CGWin.frame(of: id) ?? .zero
            if case .tab = t { overlay.show(NSScreen.fromAX(r), label: "TAB") }
            else { overlay.show(NSScreen.fromAX(r), label: "HOLD TO TAB") }
        }
    }

    private func startDwell(_ id: CGWindowID, at p: CGPoint) {
        cancelDwell()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.holdTime, repeats: false) { [weak self] _ in
            guard let self, var d = self.dwell, d.id == id else { return }
            d.fired = true
            self.dwell = d
            if let w = self.draggingID { self.dragMoved(w, at: NSScreen.axMouse()) }
        }
        dwell = (id, p, timer, false)
    }

    private func cancelDwell() { dwell?.timer.invalidate(); dwell = nil }

    private func drop(_ wid: CGWindowID, at p: CGPoint, torn: Bool) {
        guard case .tab(let other)? = target else {
            if let g = group(of: wid), g.active == wid, !torn {
                if let f = CGWin.frame(of: wid) { g.frame = groupFrame(content: f) }
                apply(g)
            } else if torn, let el = element(wid), let cur = AX.frame(el) {
                AX.setFrame(el, onScreen(cur)); AX.raise(el)      // a torn tab lands fully on screen
            }
            return
        }
        if !torn, let g = group(of: wid), g.active == wid {
            // A whole group dropped on another window: all its tabs join.
            groups.removeAll { $0 === g }
            for m in g.tabs { merge(m, onto: other) }
            if let tg = group(of: other) { tg.active = wid; apply(tg) }
        } else {
            detach(wid)
            merge(wid, onto: other)
            if let tg = group(of: other) { apply(tg) }
        }
        if let el = element(wid) { AX.raise(el) }
    }

    /// `wid` joins `target` as a tab. A plain window becomes a group, its strip taking the top of its frame.
    private func merge(_ wid: CGWindowID, onto target: CGWindowID) {
        guard wid != target else { return }
        if let g = group(of: target) { g.add(wid); return }
        guard let f = CGWin.frame(of: target) else { return }
        let g = TabGroup(tabs: [target], active: target, frame: f)
        g.add(wid)
        groups.append(g)
    }

    /// Take a window out of its group. The group carries on, or ends when one tab is left.
    private func detach(_ wid: CGWindowID) {
        guard let g = group(of: wid) else { return }
        let content = contentFrame(g)
        g.remove(wid)
        if g.isGroup { apply(g) } else { dissolve(g) }
        if let el = element(wid), let cur = AX.frame(el), !NSScreen.screens.contains(where: { $0.axFrame.intersects(cur.insetBy(dx: 4, dy: 4)) }) {
            AX.setFrame(el, content)                           // it was parked: bring it back at the group's size
        }
    }

    /// One window left: it's a normal window again, filling what the group used.
    private func dissolve(_ g: TabGroup) {
        groups.removeAll { $0 === g }
        if let w = g.tabs.first, let el = element(w) { AX.setFrame(el, g.frame.integral) }
        refreshStrips()
        save()
    }

    // MARK: Tab actions (strip, keys)

    func activate(_ wid: CGWindowID) {
        guard let g = group(of: wid) else { return }
        g.active = wid
        apply(g)
        if let el = element(wid) { AX.raise(el) }
    }

    private func cycle(_ dir: Int) {
        guard let el = AX.focusedWindow(), let w = AX.wid(el), let g = group(of: w),
              let i = g.tabs.firstIndex(of: g.active) else { return }
        let n = g.tabs.count
        activate(g.tabs[((i + dir) % n + n) % n])
    }

    func reorder(_ wid: CGWindowID, to index: Int) {
        group(of: wid)?.move(wid, to: index)
        refreshStrips(); save()
    }

    func closeTab(_ wid: CGWindowID) {
        guard let el = element(wid) else { return }
        if let btn: AXUIElement = AX.attr(el, kAXCloseButtonAttribute) { AXUIElementPerformAction(btn, kAXPressAction as CFString) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.reconcile() }
    }

    func moveOut(_ wid: CGWindowID) {
        guard let g = group(of: wid) else { return }
        let f = contentFrame(g)
        detach(wid)
        if let el = element(wid) { AX.setFrame(el, onScreen(f.offsetBy(dx: 40, dy: 40))); AX.raise(el) }
    }

    func separateAll(_ wid: CGWindowID) {
        guard let g = group(of: wid) else { return }
        let f = contentFrame(g)
        groups.removeAll { $0 === g }
        for (i, m) in g.tabs.enumerated() {
            if let el = element(m) { AX.setFrame(el, onScreen(f.offsetBy(dx: CGFloat(i) * 36, dy: CGFloat(i) * 36))) }
        }
        refreshStrips(); save()
    }

    // Tear-off: the strip moves the window with the pointer, then drops it like a normal drag.
    func tearMove(_ wid: CGWindowID, at p: CGPoint) {
        if draggingID != wid {
            draggingID = wid
            if let g = group(of: wid) {
                let size = contentFrame(g).size
                detach(wid)
                if let el = element(wid) { AX.setFrame(el, CGRect(origin: p, size: size)) }
            }
        }
        guard let el = element(wid), let f = AX.frame(el) else { return }
        AX.setFrame(el, CGRect(x: p.x - min(f.width / 2, 160), y: p.y - 12, width: f.width, height: f.height).integral)
        dragMoved(wid, at: p)
    }

    func tearEnd(_ wid: CGWindowID, at p: CGPoint) {
        overlay.hide()
        drop(wid, at: p, torn: true)
        cancelDwell()
        draggingID = nil
        target = nil
        refreshStrips()
    }

    // MARK: Strips

    func refreshStrips() {
        var keep: [TabStripPanel] = []
        if running {
            for g in groups where g.isGroup {
                let onScreen = CGWin.list().contains { $0.id == g.active }
                guard onScreen else { continue }
                let p = strips.first { s in !keep.contains { $0 === s } && !Set(s.strip.tabs).isDisjoint(with: g.tabs) }
                    ?? TabStripPanel(controller: self)
                keep.append(p)
                var r = g.frame
                r.size.height = Self.stripHeight - 4
                p.update(tabs: g.tabs.map(info), active: g.active, axFrame: r)
            }
        }
        for s in strips where !keep.contains(where: { $0 === s }) {
            if s.strip.busy { keep.append(s) } else { s.orderOut(nil) }
        }
        strips = keep
    }

    private func info(_ id: CGWindowID) -> TabInfo {
        let w = CGWin.list(onScreenOnly: false).first { $0.id == id }
        let app = w.flatMap { NSRunningApplication(processIdentifier: $0.pid) }
        var title: String = element(id).flatMap { AX.attr($0, kAXTitleAttribute) } ?? ""
        if title.isEmpty { title = app?.localizedName ?? w?.app ?? "Window" }
        return TabInfo(id: id, title: title, icon: app?.icon)
    }
}

struct TabInfo { let id: CGWindowID; let title: String; let icon: NSImage? }

// MARK: - Drop overlay (only the window under the pointer is lit)

final class DropOverlay {
    private var panel: NSPanel?
    private let view = OverlayView()

    func show(_ rect: CGRect, label: String) {
        if panel == nil {
            let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
            p.contentView = view
            panel = p
        }
        if view.label != label { view.label = label; view.needsDisplay = true }
        if panel!.frame != rect { panel!.setFrame(rect, display: true) }
        panel!.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

final class OverlayView: NSView {
    var label = ""
    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor(hex: 0xF07A42)
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 12, yRadius: 12)
        accent.withAlphaComponent(0.12).setFill(); path.fill()
        accent.setStroke(); path.lineWidth = 2; path.stroke()
        guard !label.isEmpty else { return }
        let s = NSAttributedString(string: label, attributes: [.font: PT.nsMono(10), .foregroundColor: NSColor.white, .kern: 0.8])
        let sz = s.size()
        let pill = NSRect(x: bounds.midX - sz.width / 2 - 10, y: bounds.midY - 11, width: sz.width + 20, height: 22)
        accent.setFill(); NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
        s.draw(at: NSPoint(x: pill.minX + 10, y: pill.midY - sz.height / 2))
    }
}

// MARK: - Strip panel

final class TabStripPanel: NSPanel {
    let strip = TabStripView()

    init(controller: TabGroupController) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 26),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        strip.controller = controller
        level = .normal
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        contentView = strip
    }

    override var canBecomeKey: Bool { false }

    func update(tabs: [TabInfo], active: CGWindowID, axFrame: CGRect) {
        guard !strip.busy else { return }
        strip.tabs = tabs.map(\.id)
        strip.infos = tabs
        strip.active = active
        let f = NSScreen.fromAX(axFrame)
        if frame != f { setFrame(f, display: true) }
        strip.needsDisplay = true
        // Sit right above the visible tab, so other apps' windows can still cover the group.
        order(.above, relativeTo: Int(active))
        if !isVisible { orderFrontRegardless() }
    }
}

final class TabStripView: NSView {
    weak var controller: TabGroupController?
    var tabs: [CGWindowID] = []
    var infos: [TabInfo] = []
    var active: CGWindowID = 0
    var busy: Bool { pressed != nil }

    private var pressed: (id: CGWindowID, start: NSPoint, index: Int)?
    private var tearing = false
    private var reorderX: CGFloat?
    private var hoverIndex: Int?

    private var dark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
    private static let ui: NSFont = {
        let attrs: [NSFontDescriptor.AttributeName: Any] = [
            .family: "Space Grotesk",
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [0x7767_6874: 500],
        ]
        return NSFont(descriptor: NSFontDescriptor(fontAttributes: attrs), size: 11.5) ?? .systemFont(ofSize: 11.5, weight: .medium)
    }()

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func tabRect(_ i: Int) -> NSRect {
        let n = CGFloat(max(infos.count, 1))
        let inner = bounds.insetBy(dx: 3, dy: 3)
        let w = (inner.width - 3 * (n - 1)) / n
        return NSRect(x: inner.minX + CGFloat(i) * (w + 3), y: inner.minY, width: w, height: inner.height)
    }

    private func index(at p: NSPoint) -> Int? { (0..<infos.count).first { tabRect($0).contains(p) } }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseMoved(with e: NSEvent) {
        let i = index(at: convert(e.locationInWindow, from: nil))
        if i != hoverIndex { hoverIndex = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hoverIndex = nil; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        let bg = dark ? NSColor(hex: 0x161616) : NSColor(hex: 0xF4F4F2)
        let line = dark ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.10)
        let ink = dark ? NSColor(hex: 0xF2F2F0) : NSColor(hex: 0x111111)
        let mute = dark ? NSColor(hex: 0x8A8A88) : NSColor(hex: 0x6E6E6C)
        let card = dark ? NSColor(hex: 0x2A2A2A) : NSColor.white
        let accent = NSColor(hex: 0xF07A42)

        let body = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        bg.setFill(); body.fill()
        line.setStroke(); body.lineWidth = 1; body.stroke()

        for (i, t) in infos.enumerated() {
            var r = tabRect(i)
            if let x = reorderX, let pr = pressed, pr.id == t.id, !tearing { r.origin.x = x - r.width / 2 }
            let isActive = t.id == active
            if isActive || hoverIndex == i {
                (isActive ? card : card.withAlphaComponent(0.45)).setFill()
                NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            }
            if isActive {
                accent.setFill()
                NSBezierPath(ovalIn: NSRect(x: r.minX + 8, y: r.midY - 2.5, width: 5, height: 5)).fill()
            }
            var x = r.minX + (isActive ? 19 : 10)
            if let icon = t.icon {
                icon.draw(in: NSRect(x: x, y: r.midY - 8, width: 16, height: 16), from: .zero, operation: .sourceOver,
                          fraction: isActive ? 1 : 0.7, respectFlipped: true, hints: nil)
                x += 21
            }
            let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
            let s = NSAttributedString(string: t.title, attributes: [.font: Self.ui, .foregroundColor: isActive ? ink : mute, .paragraphStyle: para])
            let h = s.size().height
            s.draw(with: NSRect(x: x, y: r.midY - h / 2, width: max(r.maxX - x - 8, 0), height: h),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = index(at: p) else { return }
        pressed = (infos[i].id, p, i)
        tearing = false; reorderX = nil
        controller?.activate(infos[i].id)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let pr = pressed else { return }
        let p = convert(e.locationInWindow, from: nil)
        if !tearing && (abs(p.y - pr.start.y) > 18 || p.x < -18 || p.x > bounds.width + 18) {
            tearing = true; reorderX = nil; needsDisplay = true
            NSCursor.closedHand.set()
        }
        if tearing {
            controller?.tearMove(pr.id, at: NSScreen.axMouse())
        } else if infos.count > 1 {
            reorderX = min(max(p.x, 0), bounds.width); needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        guard let pr = pressed else { return }
        pressed = nil
        NSCursor.arrow.set()
        if tearing {
            tearing = false
            controller?.tearEnd(pr.id, at: NSScreen.axMouse())
        } else if let x = reorderX {
            reorderX = nil
            let n = CGFloat(max(infos.count, 1))
            let target = Int(min(max(x / (bounds.width / n), 0), n - 1))
            if target != pr.index { controller?.reorder(pr.id, to: target) } else { needsDisplay = true }
        }
    }

    override func rightMouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = index(at: p), let c = controller else { return }
        let id = infos[i].id
        let m = NSMenu()
        m.autoenablesItems = false
        m.addItem(ClosureMenuItem("Close Tab", symbol: "xmark") { c.closeTab(id) })
        m.addItem(ClosureMenuItem("Move Out of Group", symbol: "macwindow.on.rectangle") { c.moveOut(id) })
        m.addItem(.separator())
        m.addItem(ClosureMenuItem("Separate All Tabs", symbol: "square.on.square") { c.separateAll(id) })
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
}
