import AppKit
import SwiftUI
import QuickLookUI

// The Nook: a black panel that grows out of the MacBook notch (or a slim pill on screens without one).
// Black like the hardware notch; every element inside uses Tatakan/Puteran tokens (Doto, Space Grotesk,
// Space Mono labels, round icon buttons, one #F07A42 accent).

enum NookTab: Int, CaseIterable { case home, tray, calendar, timer, notes
    var title: String { ["Home", "Tray", "Calendar", "Timer", "Notes"][rawValue] }
    var symbol: String { ["house", "tray", "calendar", "timer", "checklist"][rawValue] }
}

enum NookState: Equatable { case closed, peek, open }

/// Notch-side colors (always dark, independent of system appearance).
enum NK {
    static let bg = Color.black
    static let card = Color.white.opacity(0.07)
    static let card2 = Color.white.opacity(0.13)
    static let line = Color.white.opacity(0.08)       // hairline around cards
    static let line2 = Color.white.opacity(0.22)      // dashed drop targets
    static let ink = Color.white
    static let mute = Color.white.opacity(0.6)        // ≈ secondaryLabel on dark
    static let faint = Color.white.opacity(0.38)      // ≈ tertiaryLabel
    static let dot = Color.white.opacity(0.16)
}

final class NookModel: ObservableObject {
    @Published var state: NookState = .closed
    @Published var tab: NookTab = .home
    let glow = GlowDriver()
    @Published var dropHover = false {      // something is being dragged over the nook
        didSet { if dropHover != oldValue { glow.hold(dropHover) } }
    }
    @Published var hoverAirDrop = false
    @Published var activity: LiveActivity?
    var notchSize = CGSize(width: 185, height: 32)
    var hasNotch = true
}

// MARK: - Window

final class NookPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Root view: accepts drops. Left side → tray, right "AirDrop" zone → AirDrop.
final class NookDropView: NSView {
    weak var controller: NookController?
    /// Visible nook area to watch for enter/exit (empty while closed).
    var trackRect: NSRect = .zero { didSet { if trackRect != oldValue { updateTrackingAreas() } } }
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        area = nil
        guard !trackRect.isEmpty else { return }
        let a = NSTrackingArea(rect: trackRect.insetBy(dx: -6, dy: -6),
                               options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
        // If the pointer is already outside when tracking starts (e.g. opened via shortcut), treat as exit.
        if let w = window, !trackRect.insetBy(dx: -6, dy: -6).contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) {
            DispatchQueue.main.async { [weak self] in self?.controller?.nookExitedIfIdle() }
        }
    }
    override func mouseEntered(with event: NSEvent) { controller?.nookEntered() }
    override func mouseExited(with event: NSEvent) { controller?.nookExited() }
    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Ingest.draggedTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func zone(_ sender: NSDraggingInfo) -> Bool {
        guard let c = controller, c.model.state == .open else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        return c.airDropRect.contains(p)
    }
    private func isOwn(_ sender: NSDraggingInfo) -> Bool {
        (sender.draggingSource as? NSView)?.window === window
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isOwn(sender) { return [] }
        controller?.dragEntered()
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isOwn(sender) { return [] }
        controller?.model.hoverAirDrop = zone(sender)
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.dragExited() }
    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.model.dropHover = false; controller?.model.hoverAirDrop = false }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let c = controller else { return false }
        let toAirDrop = zone(sender)
        c.model.dropHover = false; c.model.hoverAirDrop = false
        return c.accept(sender.draggingPasteboard, airDrop: toAirDrop)
    }
}

final class NookController: NSObject, ShelfHost, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    let model = NookModel()
    let shelf = Shelf()
    let panel: NookPanel
    var hostWindow: NSWindow { panel }
    private let root: NookDropView
    private var mouseMonitors: [Any] = []
    private var dragTimer: Timer?
    private var closeWork: DispatchWorkItem?
    private var hoverWork: DispatchWorkItem?
    private var previewItems: [URL] = []
    private var keyMonitor: Any?
    private var screen: NSScreen

    static let openSize = CGSize(width: 680, height: 240)
    /// Transparent room around the open shape so its shadow / glass edge / glow fade out instead of
    /// being cut by the window bounds (that cut was the visible "bounding box" at the notch sides).
    static let margin = (side: CGFloat(44), bottom: CGFloat(52))
    /// Area (in root view coords) of the AirDrop drop zone while the nook is open.
    var airDropRect: CGRect {
        let s = NookController.openSize, m = NookController.margin
        return CGRect(x: m.side + s.width - NookView.inset - 132, y: m.bottom + NookView.inset,
                      width: 132, height: s.height - model.notchSize.height - 10 - NookView.inset)
    }

    init(screen: NSScreen) {
        self.screen = screen
        let frame = NookController.frame(for: screen)
        panel = NookPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        root = NookDropView(frame: NSRect(origin: .zero, size: frame.size))
        super.init()
        model.notchSize = NookController.notch(for: screen)
        model.hasNotch = screen.safeAreaInsets.top > 0

        panel.level = .statusBar + 1           // above the menu bar, like the hardware notch
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true        // clicks pass through until the pointer is on the notch

        root.controller = self
        let host = NSHostingView(rootView: NookView(controller: self, glow: model.glow)
            .environmentObject(model).environmentObject(shelf))
        // The window size is fixed and set by us. Letting SwiftUI push its ideal/min/max size into
        // Auto Layout made macOS 27 loop in updateConstraints while the notch animates → AppKit
        // raised and the app crashed (seen with the stock 0.3.0 build too).
        host.sizingOptions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.topAnchor.constraint(equalTo: root.topAnchor),
            host.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        panel.contentView = root
        panel.orderFrontRegardless()
        // Dragged files must be able to find the window even while it ignores the mouse.
        startMonitors()
        LiveActivities.shared.$current.receive(on: RunLoop.main).sink { [weak self] a in
            withAnimation(Motion.settle) { self?.model.activity = a }
        }.store(in: &bag)
        TimerModel.shared.onFinish = {
            LiveActivities.shared.show(LiveActivity(symbol: "timer", left: "Timer done", right: "00:00", accent: true), seconds: 6)
        }
    }

    private var bag = Set<AnyCancellable>()

    // Geometry ---------------------------------------------------------------
    static func notch(for s: NSScreen) -> CGSize {
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            return CGSize(width: r.minX - l.maxX, height: s.safeAreaInsets.top)
        }
        return CGSize(width: 150, height: 24)   // slim handle on notch-less displays
    }

    /// Fixed window: the full open size plus a shadow margin, centered on the notch. Content draws only what's needed.
    static func frame(for s: NSScreen) -> NSRect {
        let w = openSize.width + 2 * margin.side, h = openSize.height + margin.bottom
        return NSRect(x: s.frame.midX - w / 2, y: s.frame.maxY - h, width: w, height: h)
    }

    /// Screen-space rect of the currently visible shape (for hit testing).
    func visibleRect() -> NSRect {
        let f = panel.frame
        let n = model.notchSize
        switch model.state {
        case .open:
            let s = NookController.openSize
            return NSRect(x: f.midX - s.width / 2, y: f.maxY - s.height, width: s.width, height: s.height)
        case .peek:
            let w = n.width + 120, h = n.height + 34
            return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        case .closed:
            let w = NookView.closedWidth(notch: n, activity: model.activity != nil,
                                         playing: NowPlaying.shared.playing && Settings.shared.notchMediaPeek)
            let h = n.height
            return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        }
    }

    func reposition(to s: NSScreen) {
        screen = s
        model.notchSize = NookController.notch(for: s)
        model.hasNotch = s.safeAreaInsets.top > 0
        panel.setFrame(NookController.frame(for: s), display: true)
        sensor?.place(hotZone())
    }

    // Mouse handling -----------------------------------------------------------
    // No global mouse-move monitor (it wakes the app on every pointer move system-wide).
    // A tiny sensor window sits on the notch; tracking areas tell us when the pointer
    // enters/leaves, so the app sleeps until the notch is actually touched.
    private var sensor: NookSensor!

    private func startMonitors() {
        sensor = NookSensor(controller: self)
        sensor.place(hotZone())
        mouseMonitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // click outside an open nook → close (fires only on clicks, not moves)
            guard let self, self.model.state != .closed, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
            self.set(.closed)
        } as Any)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel else { return e }
            if e.keyCode == 53 { self.set(.closed); return nil }                                // esc
            if e.keyCode == 49, self.model.tab == .tray, !(NSApp.keyWindow?.firstResponder is NSTextView) {
                self.quickLook(); return nil
            }
            return e
        }
    }

    /// Pointer entered the notch sensor.
    func sensorEntered() {
        guard Settings.shared.notchEnabled, model.state == .closed,
              NSEvent.pressedMouseButtons & 1 == 0 else { return }
        scheduleHover()
    }
    /// Pointer moving inside the sensor: re-arm if an earlier attempt missed (no more wiggling).
    func sensorMoved() { if model.state == .closed { sensorEntered() } }
    func sensorExited() { hoverWork?.cancel(); hoverWork = nil }

    /// Hit test with slack. `NSRect.contains` excludes the top edge, and a pointer pushed against the
    /// top of the screen sits exactly on `maxY`, so the strict check failed until you wiggled down.
    private func pointerIn(_ r: NSRect, slack: CGFloat) -> Bool {
        let p = NSEvent.mouseLocation
        let z = r.insetBy(dx: -slack, dy: -slack)
        return p.x >= z.minX && p.x <= z.maxX && p.y >= z.minY && p.y <= z.maxY
    }

    /// Pointer entered / left the visible nook (tracking area on the panel).
    func nookEntered() { closeWork?.cancel(); closeWork = nil }
    /// Opened with the pointer elsewhere (shortcut / menu): keep it open until the user leaves it once.
    func nookExitedIfIdle() { if model.state == .peek { set(.closed) } }
    func nookExited() {
        guard NSEvent.pressedMouseButtons & 1 == 0, !DragSourceNSView.isDraggingOut else { return }
        if model.state == .peek { set(.closed) } else if model.state == .open { scheduleClose() }
    }

    func hotZone() -> NSRect {
        let f = panel.frame, n = model.notchSize
        let w = n.width + 40
        return NSRect(x: f.midX - w / 2, y: f.maxY - n.height - 2, width: w, height: n.height + 2)
    }

    private func scheduleHover() {
        guard hoverWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            if self.pointerIn(self.hotZone(), slack: 6), self.model.state == .closed {
                self.set(Settings.shared.notchOpenOnHover ? .open : .peek)
            }
        }
        hoverWork = w
        // short intent delay: filters a pointer just passing by, still feels instant
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09, execute: w)
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            guard self.model.state != .closed else { return }
            if self.pointerIn(self.visibleRect(), slack: 6) { return }   // came back in
            if DragSourceNSView.isDraggingOut || NSEvent.pressedMouseButtons & 1 != 0 {
                self.scheduleClose()   // still dragging: look again shortly (cheap, only while open)
                return
            }
            self.set(.closed)
        }
        closeWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: w)
    }

    func set(_ s: NookState) {
        guard model.state != s else { return }
        closeWork?.cancel(); closeWork = nil
        if s == .open {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
            // EventKit fetch runs off the main thread, after the spring has mostly played
            // (it used to block the first frames of the open animation).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { CalendarModel.shared.reload() }
            shelf.pruneDeadFiles()
        }
        if s != .open { MirrorModel.shared.stop(); panel.resignKey() }
        if s == .closed { model.glow.glassOff() } else { model.glow.glassAfter(s == .open ? 0.3 : 0.2) }
        withAnimation(s == .open ? Motion.open : Motion.close) { model.state = s }
        if s == .open { model.glow.burst() } else if s == .closed { model.glow.reset() }
        panel.ignoresMouseEvents = s == .closed
        root.trackRect = s == .closed ? .zero : panelRectInView(visibleRect())
        sensor?.place(hotZone())
    }

    private func panelRectInView(_ r: NSRect) -> NSRect {
        NSRect(x: r.minX - panel.frame.minX, y: r.minY - panel.frame.minY, width: r.width, height: r.height)
    }

    func toggleOpen() { set(model.state == .open ? .closed : .open) }

    func open(tab: NookTab) {
        model.tab = tab
        set(.open)
        panel.makeKey()
    }

    // Drag & drop ---------------------------------------------------------------
    func dragEntered() {
        model.dropHover = true
        if model.state != .open {
            model.tab = .tray
            set(.open)
        } else if model.tab != .tray && model.tab != .home {
            withAnimation(.easeOut(duration: 0.2)) { model.tab = .tray }
        }
    }

    func dragExited() {
        model.dropHover = false
        model.hoverAirDrop = false
        scheduleClose()
    }

    @discardableResult
    func accept(_ pb: NSPasteboard, airDrop: Bool) -> Bool {
        let r = Ingest.items(from: pb)
        if airDrop {
            if !r.items.isEmpty {
                Actions.send(r.items, via: .sendViaAirDrop, shelf: shelf)
                set(.closed)
                return true
            }
            return false
        }
        shelf.add(r.items)
        if !r.promises.isEmpty {
            let dir = Ingest.newTempFolder()
            for promise in r.promises {
                promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: OperationQueue()) { [weak self] url, err in
                    DispatchQueue.main.async { if err == nil { self?.shelf.add([.file(url)]) } }
                }
            }
        }
        if !r.items.isEmpty || !r.promises.isEmpty {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            model.tab = .tray
            saveTray()
            return true
        }
        return false
    }

    // Tray persistence (kept across restarts, like NotchNook)
    func saveTray() {
        UserDefaults.standard.set(try? JSONEncoder().encode(shelf.items), forKey: "nookTray")
    }
    func loadTray() {
        guard let d = UserDefaults.standard.data(forKey: "nookTray"),
              let items = try? JSONDecoder().decode([ShelfItem].self, from: d) else { return }
        shelf.items = items.filter(\.isAlive)
    }

    // ShelfHost
    func close() { shelf.remove(Set(shelf.items.map(\.id))); saveTray() }

    func quickLook() {
        previewItems = shelf.targets.compactMap { $0.kind == .file ? $0.url : nil }
        guard !previewItems.isEmpty, let ql = QLPreviewPanel.shared() else { return }
        panel.makeKey()
        ql.dataSource = self; ql.delegate = self
        ql.reloadData()
        ql.isVisible ? ql.orderOut(nil) : ql.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! { previewItems[index] as NSURL }
}

import Combine

// MARK: - Notch sensor (tiny always-on window over the notch)

final class NookSensor: NSObject {
    private let window: NSPanel
    private weak var controller: NookController?

    init(controller: NookController) {
        self.controller = controller
        window = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.level = .statusBar + 2
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false        // transparent but still hit-testable
        window.acceptsMouseMovedEvents = true
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        let v = SensorView()
        v.controller = controller
        window.contentView = v
        view = v
        window.orderFrontRegardless()
    }
    private weak var view: SensorView?

    func place(_ r: NSRect) {
        guard let c = controller else { return }
        // Only present while the nook is closed: once open, the panel itself handles everything.
        if c.model.state == .closed {
            window.setFrame(r, display: false)
            window.orderFrontRegardless()
            // The sensor was hidden while the pointer was inside it, so it never got mouseExited and
            // still thinks the pointer is in: the next approach sent no mouseEntered and hover-open
            // worked only once (after that you had to click). Fresh tracking area = fresh state.
            view?.rearm()
        } else {
            window.orderOut(nil)
        }
    }
}

final class SensorView: NSView {
    weak var controller: NookController?
    private var area: NSTrackingArea?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Ingest.draggedTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rearm()
    }
    func rearm() {
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseEntered(with event: NSEvent) { controller?.sensorEntered() }
    override func mouseExited(with event: NSEvent) { controller?.sensorExited() }
    override func mouseMoved(with event: NSEvent) { controller?.sensorMoved() }
    override func mouseDown(with event: NSEvent) { controller?.open(tab: controller?.model.tab ?? .home) }

    // A file dragged onto the notch: open the nook; the panel takes over the drag from there.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEntered()
        return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.accept(sender.draggingPasteboard, airDrop: false) ?? false
    }
}

// MARK: - Notch shape

/// Hardware-notch silhouette: flat top that flares into the menu bar, rounded bottom corners.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        var p = Path()
        let t = topRadius, b = bottomRadius
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Root view

struct NookView: View {
    let controller: NookController
    @EnvironmentObject var model: NookModel
    @ObservedObject var glow: GlowDriver
    @EnvironmentObject var shelf: Shelf
    @ObservedObject var media = NowPlaying.shared

    /// Content inset inside the open panel. ≥ panel corner (28) − card corner (16) so cards stay
    /// concentric with the glass instead of being squeezed into its corners.
    static let inset: CGFloat = 18

    /// Width added on each side of the notch while the closed island shows music / an activity.
    static func wing(activity: Bool) -> CGFloat { activity ? 84 : 40 }
    static func closedWidth(notch n: CGSize, activity: Bool, playing: Bool) -> CGFloat {
        activity || playing ? n.width + 2 * wing(activity: activity) : n.width
    }

    private var size: CGSize {
        let n = model.notchSize
        switch model.state {
        case .open: return NookController.openSize
        case .peek: return CGSize(width: n.width + 120, height: n.height + 34)
        case .closed:
            let w = Self.closedWidth(notch: n, activity: model.activity != nil,
                                     playing: media.playing && Settings.shared.notchMediaPeek)
            return CGSize(width: w, height: n.height)
        }
    }

    private var isOpen: Bool { model.state == .open }
    private var shape: NotchShape {
        NotchShape(topRadius: isOpen ? 12 : 6, bottomRadius: isOpen ? 28 : (model.state == .peek ? 16 : 10))
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                // Closed = pure black (one piece with the hardware notch). Peek/open = Liquid Glass,
                // black across the notch band, fading to clear glass towards the bottom.
                LiquidSurface(shape: shape, glass: model.state != .closed && glow.glassReady,
                              solid: min(1, model.notchSize.height / max(size.height, 1)),
                              veil: model.state == .closed ? 1 : (glow.glassReady ? 0 : 0.82))
                    .shadow(color: .black.opacity(isOpen ? 0.32 : 0), radius: 22, y: 12)
                AIBloom(driver: model.glow).mask(shape)
                content
                    .clipShape(shape)
                AIGlowRim(shape: shape, driver: model.glow)
            }
            .frame(width: size.width, height: size.height)
            // one curve for every resize: open/close, music starting/stopping, live activities
            .animation(isOpen ? Motion.open : Motion.settle, value: size)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
        // Non-activating panel: render controls as active all the time (otherwise glass, accent and
        // selection look dimmed until the panel is clicked and becomes key). Behaviour unchanged.
        .environment(\.controlActiveState, .key)
        .onTapGesture { if model.state != .open { controller.set(.open) } }
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .closed: ClosedStrip()
        case .peek: PeekView()
        case .open: OpenView(controller: controller)
        }
    }
}

// MARK: - Closed: live activity / now playing around the notch (Dynamic Island style)

struct ClosedStrip: View {
    @EnvironmentObject var model: NookModel
    @ObservedObject var media = NowPlaying.shared

    var body: some View {
        HStack(spacing: 0) {
            if let a = model.activity {
                let w = NookView.wing(activity: true) - 14
                HStack(spacing: 5) {
                    Image(systemName: a.symbol).font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(a.accent ? PT.accent : NK.ink)
                        .symbolEffect(.pulse, options: .nonRepeating, value: a)
                    Text(a.left).font(.system(size: 11, weight: .semibold)).foregroundStyle(NK.ink).lineLimit(1)
                }
                .frame(width: w, alignment: .leading)
                .transition(.island)
                Spacer(minLength: 0)
                Text(a.right).font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(a.accent ? PT.accent : NK.ink).lineLimit(1)
                    .contentTransition(.numericText())
                    .frame(width: w, alignment: .trailing)
                    .transition(.island)
            } else if media.playing && Settings.shared.notchMediaPeek {
                Artwork(size: 22, radius: 6).transition(.island)
                Spacer(minLength: 0)
                Equalizer(active: media.playing, tint: NSColor(media.tint))
                    .frame(width: 20, height: 14)
                    .transition(.island)
            }
        }
        .padding(.horizontal, 9)
        .frame(maxHeight: .infinity)
        .transition(.opacity)
    }
}

/// Hover peek: a one-line preview, click to open.
struct PeekView: View {
    @EnvironmentObject var model: NookModel
    @EnvironmentObject var shelf: Shelf
    @ObservedObject var media = NowPlaying.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: model.notchSize.height)
            HStack(spacing: 8) {
                if media.hasMedia {
                    Artwork(size: 18, radius: 5)
                    Text(media.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(NK.ink).lineLimit(1)
                } else {
                    Text("Tatakan").font(.system(size: 12, weight: .semibold)).foregroundStyle(NK.ink)
                }
                Spacer(minLength: 0)
                if !shelf.items.isEmpty {
                    Label("\(shelf.items.count)", systemImage: "tray.full").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NK.mute)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 9)
        }
        .transition(.aiReveal)
    }
}

// MARK: - Open

struct OpenView: View {
    let controller: NookController
    @EnvironmentObject var model: NookModel
    @EnvironmentObject var shelf: Shelf
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 0) {
            // Row on either side of the hardware notch: tabs left, tools right.
            HStack(spacing: 0) {
                HStack(spacing: 2) { ForEach([NookTab.home, .tray, .calendar], id: \.self) { tabButton($0) } }
                Spacer(minLength: model.notchSize.width + 8)
                HStack(spacing: 2) {
                    ForEach([NookTab.timer, .notes], id: \.self) { tabButton($0) }
                    IconButton(symbol: "gearshape", help: "Settings") {
                        NSApp.sendAction(#selector(AppDelegate.openSettingsAction), to: nil, from: nil)
                    }
                }
            }
            .frame(height: model.notchSize.height)
            .padding(.horizontal, NookView.inset - 2)

            Group {
                switch model.tab {
                case .home: HomeTab(controller: controller)
                case .tray: TrayTab(controller: controller)
                case .calendar: CalendarTab()
                case .timer: TimerTab()
                case .notes: NotesTab(controller: controller)
                }
            }
            .id(model.tab)
            .transition(.tabSwap)
            .padding(.horizontal, NookView.inset).padding(.top, 10).padding(.bottom, NookView.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.aiReveal)
    }

    /// Native segmented look: SF Symbol tabs, the selection is a Liquid Glass lens that slides.
    private func tabButton(_ t: NookTab) -> some View {
        let on = model.tab == t
        return Button { withAnimation(Motion.snappy) { model.tab = t } } label: {
            HStack(spacing: 4) {
                Image(systemName: t.symbol).font(.system(size: 12.5, weight: .medium))
                if t == .tray && !shelf.items.isEmpty {
                    Text("\(shelf.items.count)").font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .contentTransition(.numericText())
                }
            }
            .foregroundStyle(on ? NK.ink : NK.mute)
            .padding(.horizontal, 10).frame(height: 26)
            .background {
                if on {
                    Color.clear
                        .interactiveGlassCapsule()
                        .matchedGeometryEffect(id: "tab", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(PressScale())
        .help(t.title)
    }
}

// MARK: Home: media + next event + tray

struct HomeTab: View {
    let controller: NookController
    @EnvironmentObject var model: NookModel
    @EnvironmentObject var shelf: Shelf
    @ObservedObject var cal = CalendarModel.shared

    var body: some View {
        HStack(spacing: 12) {
            MediaCard().frame(width: 320)
            VStack(spacing: 12) {
                NKCard {
                    VStack(alignment: .leading, spacing: 6) {
                        NKLabel(Self.dateLabel)
                        if let e = cal.events.first(where: { ($0.endDate ?? .distantPast) > Date() }) {
                            HStack(spacing: 8) {
                                Capsule().fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title ?? "Event").font(.system(size: 13, weight: .semibold)).foregroundStyle(NK.ink).lineLimit(1)
                                    NKLabel(e.isAllDay ? "All day" : Self.time.string(from: e.startDate))
                                }
                            }
                            .transition(.opacity)
                        } else {
                            Text(cal.granted ? "Nothing else today" : "Calendar off")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(NK.mute)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(Motion.quick, value: cal.events.count)
                }
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(Motion.snappy) { model.tab = .calendar } }
                TrayMini(controller: controller)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(Motion.snappy) { model.tab = .tray } }
            }
        }
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let dateFmt: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("EEEE d MMM"); return f }()
    static var dateLabel: String { dateFmt.string(from: Date()) }
}

struct TrayMini: View {
    let controller: NookController
    @EnvironmentObject var shelf: Shelf
    @EnvironmentObject var model: NookModel
    var body: some View {
        NKCard(highlight: model.dropHover) {
            HStack(spacing: 10) {
                if shelf.items.isEmpty {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(model.dropHover ? PT.accent : NK.mute)
                        .symbolEffect(.bounce, value: model.dropHover)
                    Text(model.dropHover ? "Release to keep" : "Drop files here")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(NK.mute)
                } else {
                    HStack(spacing: -10) {
                        ForEach(shelf.items.suffix(3)) { Thumb(item: $0, size: 26) }
                    }
                    Text("\(shelf.items.count) in Tray").font(.system(size: 12, weight: .medium)).foregroundStyle(NK.mute)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(NK.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Now playing (Control Center style)

struct MediaCard: View {
    @ObservedObject var media = NowPlaying.shared
    @StateObject private var scrub = ScrubState()

    var body: some View {
        NKCard(padding: 14) {
            if media.hasMedia {
                HStack(spacing: 14) {
                    // Artwork breathes with playback: full size + coloured glow while playing.
                    Artwork(size: 84, radius: 12)
                        .scaleEffect(media.playing ? 1 : 0.9)
                        .shadow(color: media.tint.opacity(media.playing ? 0.45 : 0), radius: 18, y: 6)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(media.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(NK.ink).lineLimit(1)
                            .id(media.title).transition(.tabSwap)
                        Text(media.artist.isEmpty ? media.appName : media.artist)
                            .font(.system(size: 12)).foregroundStyle(NK.mute).lineLimit(1)
                            .id(media.artist).transition(.tabSwap)
                        Spacer(minLength: 6)
                        ProgressRow(scrub: scrub)
                        Spacer(minLength: 4)
                        HStack(spacing: 2) {
                            TransportButton(symbol: "backward.fill", size: 14, help: "Previous") { media.previous() }
                            TransportButton(symbol: media.playing ? "pause.fill" : "play.fill", size: 21, help: "Play/Pause") { media.toggle() }
                            TransportButton(symbol: "forward.fill", size: 14, help: "Next") { media.next() }
                            Spacer(minLength: 0)
                            if !media.appName.isEmpty && !media.artist.isEmpty {   // else it's already the subtitle
                                Text(media.appName).font(.system(size: 11, weight: .medium)).foregroundStyle(NK.faint).lineLimit(1)
                            }
                        }
                        .padding(.leading, -8)
                    }
                    .animation(Motion.quick, value: media.title)
                }
                .animation(Motion.settle, value: media.playing)
            } else {
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NK.card2)
                        .frame(width: 84, height: 84)
                        .overlay(Image(systemName: "music.note").font(.system(size: 26, weight: .light)).foregroundStyle(NK.mute))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Not Playing").font(.system(size: 15, weight: .semibold)).foregroundStyle(NK.ink)
                        Text("Play something in Music, Spotify or a browser")
                            .font(.system(size: 12)).foregroundStyle(NK.mute).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    static func fmt(_ t: Double) -> String {
        let s = Int(t.isFinite ? t : 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

final class ScrubState: ObservableObject { @Published var value: Double? }

/// Scrubber + times. Redraws per frame only while playing (smooth, not 2 Hz jumps), paused otherwise.
struct ProgressRow: View {
    @ObservedObject var media = NowPlaying.shared
    @ObservedObject var scrub: ScrubState
    @StateObject private var hv = HoverBox()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !media.playing || scrub.value != nil)) { ctx in
            let pos = scrub.value ?? media.position(at: ctx.date)
            VStack(spacing: 4) {
                ProgressPill(value: media.duration > 0 ? pos / media.duration : 0, thick: hv.on || scrub.value != nil) { f in
                    scrub.value = f * media.duration
                } onEnd: { f in
                    media.seek(f * media.duration); scrub.value = nil
                }
                HStack {
                    Text(MediaCard.fmt(pos))
                    Spacer()
                    Text("-" + MediaCard.fmt(max(0, media.duration - pos)))
                }
                .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(NK.faint)
            }
        }
        .onHover { h in withAnimation(Motion.quick) { hv.on = h } }
    }
}

struct ProgressPill: View {
    var value: Double
    var thick = false
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h: CGFloat = thick ? 7 : 4
            ZStack(alignment: .leading) {
                Capsule().fill(NK.card2)
                Capsule().fill(NK.ink).frame(width: max(h, w * min(max(value, 0), 1)))
            }
            .frame(height: h)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onChange(min(max($0.location.x / w, 0), 1)) }
                .onEnded { onEnd(min(max($0.location.x / w, 0), 1)) })
        }
        .frame(height: 9)
    }
}

/// Plain SF Symbol transport control (like Control Center): hover halo, press squish,
/// play ↔ pause morphs with the symbol replace effect.
struct TransportButton: View {
    let symbol: String
    var size: CGFloat
    var help = ""
    let action: () -> Void
    @StateObject private var hv = HoverBox()
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(NK.ink)
                .frame(width: size + 18, height: size + 16)
                .background(Circle().fill(Color.white.opacity(hv.on ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(Motion.quick) { hv.on = h } }
        .help(help)
    }
}

struct Artwork: View {
    var size: CGFloat
    var radius: CGFloat
    @ObservedObject var media = NowPlaying.shared
    var body: some View {
        ZStack {
            if let a = media.art {
                Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
                    .id(ObjectIdentifier(a))                 // cross-fade on track change
                    .transition(.opacity)
            } else {
                NK.card2.overlay(Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(NK.mute))
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

/// Small animated bars next to the notch while music plays.
/// Core Animation runs the bars in the window server, so the app itself stays idle (no per-frame SwiftUI work).
struct Equalizer: NSViewRepresentable {
    var active: Bool
    var tint: NSColor = .white
    func makeNSView(context: Context) -> EqualizerView { EqualizerView() }
    func updateNSView(_ v: EqualizerView, context: Context) { v.setTint(tint); v.setActive(active) }
}

final class EqualizerView: NSView {
    private var bars: [CALayer] = []
    private var isActive = false
    private static let rest: CGFloat = 0.28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let b = CALayer()
            b.backgroundColor = NSColor.white.cgColor
            b.cornerRadius = 1.5
            b.transform = CATransform3DMakeScale(1, Self.rest, 1)
            layer?.addSublayer(b)
            bars.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w: CGFloat = 3, gap: CGFloat = 2.5, h = bounds.height
        let total = CGFloat(bars.count) * w + CGFloat(bars.count - 1) * gap
        var x = (bounds.width - total) / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for b in bars {
            b.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            b.position = CGPoint(x: x + w / 2, y: h / 2)
            x += w + gap
        }
        CATransaction.commit()
        // Only (re)start when missing: restarting on every layout pass made the bars jump.
        if isActive && window != nil && bars.first?.animation(forKey: "eq") == nil { start() }
    }

    func setTint(_ c: NSColor) {
        let cg = c.cgColor
        guard bars.first?.backgroundColor != cg else { return }
        CATransaction.begin(); CATransaction.setAnimationDuration(0.6)
        bars.forEach { $0.backgroundColor = cg }       // implicit, cross-fades with the artwork
        CATransaction.commit()
    }

    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        on ? start() : stop()
    }

    /// Each bar loops a different smooth curve that starts and ends at rest, so the loop seam and
    /// the start from silence are invisible.
    private func start() {
        for (i, b) in bars.enumerated() {
            var vals: [CGFloat] = [Self.rest]
            for _ in 0..<6 { vals.append(.random(in: 0.35...1.0)) }
            vals.append(Self.rest)
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = vals.map { NSNumber(value: Double($0)) }
            a.calculationMode = .cubic
            a.duration = 2.2 + Double(i) * 0.37
            a.repeatCount = .infinity
            a.beginTime = CACurrentMediaTime() + Double(i) * 0.06
            a.fillMode = .backwards
            b.add(a, forKey: "eq")
        }
    }

    /// Settle from wherever each bar is to rest instead of snapping.
    private func stop() {
        for b in bars {
            let now = (b.presentation()?.value(forKeyPath: "transform.scale.y") as? CGFloat) ?? Self.rest
            b.removeAnimation(forKey: "eq")
            let s = CABasicAnimation(keyPath: "transform.scale.y")
            s.fromValue = now; s.toValue = Self.rest
            s.duration = 0.35; s.timingFunction = CAMediaTimingFunction(name: .easeOut)
            b.add(s, forKey: "settle")
        }
    }

    // Pause the animation when the window is hidden / screen is asleep.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { bars.forEach { $0.removeAnimation(forKey: "eq") } } else if isActive { start() }
    }
}

// MARK: Tray

struct TrayTab: View {
    let controller: NookController
    @EnvironmentObject var shelf: Shelf
    @EnvironmentObject var model: NookModel
    @ObservedObject var settings = Settings.shared

    var body: some View {
        HStack(spacing: 12) {
            NKCard(highlight: model.dropHover && !model.hoverAirDrop, padding: 10) {
                if shelf.items.isEmpty {
                    DropZone(active: model.dropHover && !model.hoverAirDrop,
                             title: "Drop files here", subtitle: "They stay until you take them")
                } else {
                    VStack(spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(shelf.items) { item in
                                    TrayTile(item: item, selected: shelf.selection.contains(item.id))
                                        .overlay(DragSource(items: { dragSet(item) },
                                                            onClick: { mods in click(item, mods) },
                                                            onDoubleClick: { Actions.open([item]) },
                                                            menu: {
                                                                if !shelf.selection.contains(item.id) { shelf.selection = [item.id] }
                                                                return ItemMenu.build(for: shelf.targets, controller: controller)
                                                            },
                                                            onEnded: { op in afterDrag(dragSet(item), op) }))
                                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                                }
                            }
                            .padding(2)
                            .animation(Motion.settle, value: shelf.items.map(\.id))
                        }
                        HStack(spacing: 6) {
                            Text(shelf.status ?? (shelf.selection.isEmpty ? "\(shelf.items.count) items · drag out, ⌘-click to select"
                                                                          : "\(shelf.selection.count) selected"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(shelf.status != nil ? NK.ink : NK.mute).lineLimit(1)
                                .contentTransition(.numericText())
                            Spacer()
                            NKRound(symbol: "doc.on.clipboard", help: "Paste") { Actions.paste(into: shelf); controller.saveTray() }
                            NKShare(shelf: shelf)
                            NKRound(symbol: "ellipsis", help: "Actions") {
                                let m = ItemMenu.build(for: shelf.targets, controller: controller)
                                m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                            }
                            NKRound(symbol: "trash", help: "Clear tray") { withAnimation(Motion.settle) { controller.close() } }
                        }
                        .padding(.horizontal, 4)
                    }
                }
            }
            AirDropZone(hover: model.hoverAirDrop) {
                Actions.send(shelf.targets, via: .sendViaAirDrop, shelf: shelf)
            }
            .frame(width: 132)
        }
        .onChange(of: shelf.items) { _, _ in controller.saveTray() }
    }

    private func dragSet(_ item: ShelfItem) -> [ShelfItem] {
        shelf.selection.contains(item.id) ? shelf.items.filter { shelf.selection.contains($0.id) } : [item]
    }
    private func click(_ item: ShelfItem, _ mods: NSEvent.ModifierFlags) {
        withAnimation(Motion.quick) {
            if mods.contains(.command) || mods.contains(.shift) {
                if shelf.selection.contains(item.id) { shelf.selection.remove(item.id) } else { shelf.selection.insert(item.id) }
            } else {
                shelf.selection = shelf.selection == [item.id] ? [] : [item.id]
            }
        }
        controller.panel.makeKey()
    }
    private func afterDrag(_ items: [ShelfItem], _ op: NSDragOperation) {
        guard op != [] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            withAnimation(Motion.settle) {
                shelf.pruneDeadFiles()
                if settings.removeAfterDrag { shelf.remove(Set(items.map(\.id))) }
            }
            controller.saveTray()
        }
    }
}

/// Finder-style icon tile: grey plate around the icon + accent capsule behind the name when selected.
struct TrayTile: View {
    let item: ShelfItem
    let selected: Bool
    var body: some View {
        VStack(spacing: 4) {
            Thumb(item: item, size: 50)
                .frame(width: 62, height: 58)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : 0)))
            Text(item.title).font(.system(size: 10.5, weight: .medium)).foregroundStyle(NK.ink)
                .lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(selected ? PT.accent : .clear))
                .frame(width: 74)
        }
        .padding(.vertical, 3)
    }
}

/// Native dashed drop target.
struct DropZone: View {
    var active: Bool
    var title: String
    var subtitle: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .regular))
                .foregroundStyle(active ? PT.accent : NK.mute)
                .symbolEffect(.bounce, value: active)
            Text(active ? "Release to keep" : title).font(.system(size: 13, weight: .semibold)).foregroundStyle(NK.ink)
            Text(subtitle).font(.system(size: 11)).foregroundStyle(NK.mute)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(active ? PT.accent : NK.line2, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
        .animation(Motion.quick, value: active)
    }
}

struct AirDropZone: View {
    var hover: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AirDropGlyph(size: 30).foregroundStyle(hover ? PT.accent : NK.ink)
                    .symbolEffect(.bounce, value: hover)
                Text("AirDrop").font(.system(size: 12, weight: .semibold)).foregroundStyle(hover ? PT.accent : NK.mute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hover ? PT.accent.opacity(0.18) : NK.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(hover ? PT.accent : NK.line2, style: StrokeStyle(lineWidth: hover ? 1.5 : 1, dash: hover ? [] : [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .help("Drop files here to AirDrop · or click to AirDrop the tray")
        .animation(Motion.quick, value: hover)
    }
}

// MARK: Calendar

struct CalendarTab: View {
    @ObservedObject var cal = CalendarModel.shared

    var body: some View {
        HStack(spacing: 12) {
            NKCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.month.string(from: cal.day)).font(.system(size: 12, weight: .medium)).foregroundStyle(NK.mute)
                    Text(Self.dayNum.string(from: cal.day)).font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Calendar.current.isDateInToday(cal.day) ? PT.accent : NK.ink)
                        .contentTransition(.numericText())
                    Text(Self.weekday.string(from: cal.day)).font(.system(size: 13, weight: .semibold)).foregroundStyle(NK.ink)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        NKRound(symbol: "chevron.left", help: "Previous day") { withAnimation(Motion.snappy) { cal.shift(-1) } }
                        NKRound(symbol: "smallcircle.filled.circle", help: "Today") {
                            withAnimation(Motion.snappy) { cal.day = Calendar.current.startOfDay(for: Date()) }; cal.reload()
                        }
                        NKRound(symbol: "chevron.right", help: "Next day") { withAnimation(Motion.snappy) { cal.shift(1) } }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(width: 160)

            NKCard {
                if !cal.granted {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Calendar").font(.system(size: 15, weight: .semibold)).foregroundStyle(NK.ink)
                        Text("Allow access to show your events here.").font(.system(size: 12)).foregroundStyle(NK.mute)
                        Button("Allow Access") { cal.request() }
                            .prominentGlassButton().controlSize(.small).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else if cal.events.isEmpty {
                    VStack(spacing: 4) {
                        Image(systemName: "calendar").font(.system(size: 22, weight: .regular)).foregroundStyle(NK.mute)
                        Text("No Events").font(.system(size: 13, weight: .semibold)).foregroundStyle(NK.ink)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(cal.events, id: \.eventIdentifier) { e in
                                let past = (e.endDate ?? .distantFuture) < Date()
                                HStack(spacing: 8) {
                                    Capsule().fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 28)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.title ?? "Event").font(.system(size: 13, weight: .semibold)).foregroundStyle(past ? NK.mute : NK.ink).lineLimit(1)
                                        NKLabel(e.isAllDay ? "All day" : "\(HomeTab.time.string(from: e.startDate)) – \(HomeTab.time.string(from: e.endDate))")
                                    }
                                    Spacer(minLength: 0)
                                    if let loc = e.location, !loc.isEmpty { NKLabel(loc).frame(maxWidth: 140, alignment: .trailing) }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
    }

    static let month: DateFormatter = { let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMMM yyyy"); return f }()
    static let dayNum: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d"; return f }()
    static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE"; return f }()
}

// MARK: Timer + Mirror

struct TimerTab: View {
    @ObservedObject var t = TimerModel.shared
    @ObservedObject var mirror = MirrorModel.shared

    var body: some View {
        HStack(spacing: 12) {
            NKCard {
                HStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(NK.card2, lineWidth: 6)
                        Circle().trim(from: 0, to: t.total > 0 ? t.remaining / t.total : 0)
                            .stroke(t.running ? PT.accent : NK.ink, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.25), value: t.remaining)
                        Text(t.label).font(.system(size: t.remaining >= 3600 ? 18 : 24, weight: .semibold, design: .rounded).monospacedDigit())
                            .foregroundStyle(t.finished ? PT.accent : NK.ink)
                            .contentTransition(.numericText(countsDown: true))
                            .animation(Motion.quick, value: t.label)
                    }
                    .frame(width: 100, height: 100)
                    .padding(.leading, 4)
                    .onScrollWheel { dy in if !t.running { t.nudge(dy > 0 ? 1 : -1) } }
                    .help("Scroll to adjust")

                    VStack(alignment: .leading, spacing: 10) {
                        NKLabel(t.running ? "Running" : (t.finished ? "Done" : "Scroll the dial or pick a preset"))
                        HStack(spacing: 6) {
                            ForEach([5, 15, 25, 45, 60], id: \.self) { m in
                                Button { withAnimation(Motion.settle) { t.set(minutes: m) } } label: {
                                    Text("\(m)").font(.system(size: 11, weight: .semibold).monospacedDigit()).foregroundStyle(NK.ink)
                                        .frame(width: 32, height: 24)
                                        .background(Capsule().fill(NK.card2))
                                }.buttonStyle(PressScale())
                            }
                        }
                        HStack(spacing: 8) {
                            NKRound(symbol: "minus", help: "−1 min") { t.nudge(-1) }
                            NKRound(symbol: t.running ? "pause.fill" : "play.fill", help: "Start / pause", primary: true) { t.toggle() }
                            NKRound(symbol: "plus", help: "+1 min") { t.nudge(1) }
                            NKRound(symbol: "arrow.counterclockwise", help: "Reset") { withAnimation(Motion.settle) { t.stop() } }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            NKCard(padding: 0) {
                ZStack {
                    if mirror.running {
                        MirrorPreview(session: mirror.session).transition(.opacity)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: mirror.denied ? "video.slash" : "person.crop.square")
                                .font(.system(size: 22, weight: .light)).foregroundStyle(NK.mute)
                            Text("Mirror").font(.system(size: 12, weight: .semibold)).foregroundStyle(NK.mute)
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { mirror.running ? mirror.stop() : mirror.start() }
                .animation(Motion.settle, value: mirror.running)
                .help(mirror.denied ? "Camera access is off in System Settings" : "Click for a quick look at yourself")
            }
            .frame(width: 160)
        }
    }
}

/// Scroll-wheel helper (SwiftUI has no scroll-wheel event outside ScrollView).
struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { V(onScroll: onScroll) }
    func updateNSView(_ v: NSView, context: Context) { (v as? V)?.onScroll = onScroll }
    final class V: NSView {
        var onScroll: (CGFloat) -> Void
        private var acc: CGFloat = 0
        init(onScroll: @escaping (CGFloat) -> Void) { self.onScroll = onScroll; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func scrollWheel(with e: NSEvent) {
            acc += e.scrollingDeltaY
            let step: CGFloat = e.hasPreciseScrollingDeltas ? 18 : 1
            while abs(acc) >= step {
                onScroll(acc > 0 ? 1 : -1)
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                acc -= acc > 0 ? step : -step
            }
        }
    }
}

extension View {
    func onScrollWheel(_ f: @escaping (CGFloat) -> Void) -> some View { overlay(ScrollCatcher(onScroll: f)) }
}

// MARK: Notes + To-do

struct NotesTab: View {
    let controller: NookController
    @ObservedObject var n = NotesModel.shared

    var body: some View {
        HStack(spacing: 12) {
            NKCard {
                VStack(alignment: .leading, spacing: 6) {
                    NKLabel("Note")
                    TextEditor(text: $n.note)
                        .font(.system(size: 13)).foregroundStyle(NK.ink)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                }
            }
            NKCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 13)).foregroundStyle(NK.mute)
                        TextField("Add a to-do", text: $n.draft, onCommit: { withAnimation(Motion.settle) { n.add() } })
                            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(NK.ink)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NK.card))
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(n.todos) { t in
                                HStack(spacing: 8) {
                                    Button { withAnimation(Motion.settle) { n.toggle(t) } } label: {
                                        Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 13))
                                            .foregroundStyle(t.done ? PT.accent : NK.mute)
                                            .contentTransition(.symbolEffect(.replace))
                                    }.buttonStyle(PressScale())
                                    Text(t.text).font(.system(size: 13))
                                        .foregroundStyle(t.done ? NK.mute : NK.ink)
                                        .strikethrough(t.done, color: NK.mute).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button { withAnimation(Motion.settle) { n.star(t) } } label: {
                                        Image(systemName: t.starred ? "star.fill" : "star").font(.system(size: 11))
                                            .foregroundStyle(t.starred ? Color.yellow : NK.mute)
                                            .contentTransition(.symbolEffect(.replace))
                                    }.buttonStyle(PressScale())
                                    Button { withAnimation(Motion.settle) { n.remove(t) } } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(NK.mute)
                                    }.buttonStyle(PressScale())
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
        .onAppear { controller.panel.makeKey() }
    }
}

// MARK: - Notch-side building blocks (dark, native)

struct NKCard<Content: View>: View {
    var highlight = false
    var padding: CGFloat = 14
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(highlight ? PT.accent.opacity(0.16) : NK.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(highlight ? PT.accent : NK.line, lineWidth: highlight ? 1.5 : 0.5))
            .animation(Motion.quick, value: highlight)
    }
}

struct NKLabel: View {
    let text: String
    var color: Color = NK.mute
    init(_ t: String, color: Color = NK.mute) { text = t; self.color = color }
    var body: some View { Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(color).lineLimit(1) }
}

/// Round control on a card (Control Center style): soft fill, hover lift, press squish.
struct NKRound: View {
    let symbol: String
    var help = ""
    var primary = false
    let action: () -> Void
    @StateObject private var hv = HoverBox()
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: primary ? 13 : 11, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .foregroundStyle(primary ? Color.black : NK.ink)
                .frame(width: primary ? 32 : 26, height: primary ? 32 : 26)
                .background(Circle().fill(primary ? Color.white.opacity(hv.on ? 0.85 : 1) : Color.white.opacity(hv.on ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(Motion.quick) { hv.on = h } }
        .help(help)
    }
}

/// Bare icon in the top row (settings).
struct IconButton: View {
    let symbol: String
    var help = ""
    let action: () -> Void
    @StateObject private var hv = HoverBox()
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(hv.on ? NK.ink : NK.mute)
                .frame(width: 30, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(Motion.quick) { hv.on = h } }
        .help(help)
    }
}

struct NKShare: View {
    @ObservedObject var shelf: Shelf
    var body: some View {
        AnchoredButton(symbol: "square.and.arrow.up", help: "Share") { v in Actions.share(shelf.targets, from: v, rect: v.bounds) }
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(0.1)))
    }
}

/// Press feedback used by every custom control: quick squish with a little spring back.
struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(duration: 0.28, bounce: 0.45), value: configuration.isPressed)
    }
}
