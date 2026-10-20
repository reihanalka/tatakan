import AppKit
import SwiftUI
import QuickLookUI

// The Nook: a black panel that grows out of the MacBook notch (or a slim pill on screens without one).
// Black like the hardware notch; every element inside uses Tatakan/Puteran tokens (Doto, Space Grotesk,
// Space Mono labels, round icon buttons, one #F07A42 accent).

enum NookTab: Int, CaseIterable { case home, tray, calendar, timer, notes
    var label: String { ["NOOK", "TRAY", "CAL", "TIMER", "NOTES"][rawValue] }
}

enum NookState: Equatable { case closed, peek, open }

/// Notch-side colors (always dark, independent of system appearance).
enum NK {
    static let bg = Color.black
    static let card = Color.white.opacity(0.08)
    static let card2 = Color.white.opacity(0.14)
    static let line = Color.white.opacity(0.12)
    static let ink = Color(white: 0.95)
    static let mute = Color(white: 0.55)
    static let dot = Color.white.opacity(0.16)
}

final class NookModel: ObservableObject {
    @Published var state: NookState = .closed
    @Published var tab: NookTab = .home
    @Published var dropHover = false        // something is being dragged over the nook
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

    static let openSize = CGSize(width: 640, height: 214)
    /// Area (in root view coords) of the AirDrop drop zone while the nook is open.
    var airDropRect: CGRect {
        let s = NookController.openSize
        return CGRect(x: s.width - 18 - 132, y: 14, width: 132, height: s.height - model.notchSize.height - 36)
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
        let host = NSHostingView(rootView: NookView(controller: self)
            .environmentObject(model).environmentObject(shelf))
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
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self?.model.activity = a }
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

    /// Fixed window: the full open size, centered on the notch. Content draws only what's needed.
    static func frame(for s: NSScreen) -> NSRect {
        let size = openSize
        return NSRect(x: s.frame.midX - size.width / 2, y: s.frame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Screen-space rect of the currently visible shape (for hit testing).
    func visibleRect() -> NSRect {
        let f = panel.frame
        let n = model.notchSize
        switch model.state {
        case .open: return f
        case .peek:
            let w = n.width + 120, h = n.height + 34
            return NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
        case .closed:
            let w = (model.activity != nil || NowPlaying.shared.playing ? n.width + 110 : n.width), h = n.height
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
    func sensorExited() { hoverWork?.cancel(); hoverWork = nil }

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
        let w = n.width + 20
        return NSRect(x: f.midX - w / 2, y: f.maxY - n.height - 2, width: w, height: n.height + 2)
    }

    private func scheduleHover() {
        guard hoverWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWork = nil
            if self.hotZone().contains(NSEvent.mouseLocation), self.model.state == .closed {
                self.set(Settings.shared.notchOpenOnHover ? .open : .peek)
            }
        }
        hoverWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: w)
    }

    private func scheduleClose() {
        guard closeWork == nil else { return }
        let w = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.closeWork = nil
            guard self.model.state != .closed else { return }
            let p = NSEvent.mouseLocation
            if self.visibleRect().insetBy(dx: -6, dy: -6).contains(p) { return }   // came back in
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
            CalendarModel.shared.reload()
            shelf.pruneDeadFiles()
        }
        if s != .open { MirrorModel.shared.stop(); panel.resignKey() }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { model.state = s }
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
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        let v = SensorView()
        v.controller = controller
        window.contentView = v
        window.orderFrontRegardless()
    }

    func place(_ r: NSRect) {
        guard let c = controller else { return }
        // Only present while the nook is closed: once open, the panel itself handles everything.
        if c.model.state == .closed {
            window.setFrame(r, display: false)
            window.orderFrontRegardless()
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
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(a); area = a
    }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
    override func mouseEntered(with event: NSEvent) { controller?.sensorEntered() }
    override func mouseExited(with event: NSEvent) { controller?.sensorExited() }
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
    @EnvironmentObject var shelf: Shelf
    @ObservedObject var media = NowPlaying.shared

    private var size: CGSize {
        let n = model.notchSize
        switch model.state {
        case .open: return NookController.openSize
        case .peek: return CGSize(width: n.width + 120, height: n.height + 34)
        case .closed:
            let wide = model.activity != nil || (media.playing && Settings.shared.notchMediaPeek)
            return CGSize(width: wide ? n.width + 110 : n.width, height: n.height)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: model.state == .open ? 10 : 6, bottomRadius: model.state == .open ? 26 : 10)
                    .fill(NK.bg)
                    .shadow(color: .black.opacity(model.state == .open ? 0.45 : 0), radius: 14, y: 6)
                content
                    .padding(.horizontal, model.state == .open ? 10 : 6)   // inside the flare
                    .clipped()
            }
            .frame(width: size.width, height: size.height)
            // No outline on the notch itself while dragging: only the box under the pointer lights up.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
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

// MARK: - Closed: live activity / now playing around the notch

struct ClosedStrip: View {
    @EnvironmentObject var model: NookModel
    @ObservedObject var media = NowPlaying.shared

    var body: some View {
        HStack(spacing: 0) {
            if let a = model.activity {
                HStack(spacing: 6) {
                    Image(systemName: a.symbol).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(a.accent ? PT.accent : NK.ink)
                    Text(a.left).font(PT.ui(11, 600)).foregroundStyle(NK.ink).lineLimit(1)
                }
                .frame(width: 100, alignment: .leading)
                Spacer(minLength: model.notchSize.width - 30)
                Text(a.right).font(PT.dot(14)).foregroundStyle(a.accent ? PT.accent : NK.ink).lineLimit(1)
                    .frame(width: 60, alignment: .trailing)
            } else if media.playing && Settings.shared.notchMediaPeek {
                Artwork(size: 20, radius: 5)
                Spacer(minLength: 0)
                Equalizer(active: media.playing).frame(width: 22, height: 14)
            }
        }
        .padding(.horizontal, 12)
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
                    Artwork(size: 18, radius: 4)
                    Text(media.title).font(PT.ui(11, 600)).foregroundStyle(NK.ink).lineLimit(1)
                } else {
                    Text("TATAKAN").font(PT.dot(13)).tracking(1).foregroundStyle(NK.ink)
                }
                Spacer(minLength: 0)
                if !shelf.items.isEmpty {
                    Text(PT.n2(shelf.items.count)).font(PT.dot(13)).foregroundStyle(PT.accent)
                }
            }
            .padding(.horizontal, 18).padding(.bottom, 9)
        }
        .transition(.opacity)
    }
}

// MARK: - Open

struct OpenView: View {
    let controller: NookController
    @EnvironmentObject var model: NookModel
    @EnvironmentObject var shelf: Shelf

    var body: some View {
        VStack(spacing: 0) {
            // Row on either side of the hardware notch: tabs left, tools right.
            HStack(spacing: 0) {
                HStack(spacing: 2) {
                    ForEach([NookTab.home, .tray, .calendar], id: \.self) { tabButton($0) }
                }
                Spacer(minLength: model.notchSize.width + 8)
                HStack(spacing: 2) {
                    ForEach([NookTab.timer, .notes], id: \.self) { tabButton($0) }
                    NKRound(symbol: "gearshape", help: "Settings") { NSApp.sendAction(#selector(AppDelegate.openSettingsAction), to: nil, from: nil) }
                }
            }
            .frame(height: model.notchSize.height)
            .padding(.horizontal, 10)

            Group {
                switch model.tab {
                case .home: HomeTab(controller: controller)
                case .tray: TrayTab(controller: controller)
                case .calendar: CalendarTab()
                case .timer: TimerTab()
                case .notes: NotesTab(controller: controller)
                }
            }
            .padding(.horizontal, 14).padding(.top, 6).padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    private func tabButton(_ t: NookTab) -> some View {
        let on = model.tab == t
        return Button { withAnimation(.easeOut(duration: 0.15)) { model.tab = t } } label: {
            HStack(spacing: 4) {
                Text(t.label).font(PT.mono(9.5)).tracking(1)
                if t == .tray && !shelf.items.isEmpty {
                    Text(PT.n2(shelf.items.count)).font(PT.mono(9.5, bold: true))
                        .foregroundStyle(on ? PT.accent : PT.accent.opacity(0.9))
                }
            }
            .foregroundStyle(on ? Color.black : NK.mute)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(on ? NK.ink : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Home: media + tray strip + next event

struct HomeTab: View {
    let controller: NookController
    @EnvironmentObject var model: NookModel
    @EnvironmentObject var shelf: Shelf
    @ObservedObject var cal = CalendarModel.shared

    var body: some View {
        HStack(spacing: 10) {
            MediaCard().frame(width: 300)
            VStack(spacing: 10) {
                NKCard {
                    VStack(alignment: .leading, spacing: 6) {
                        NKLabel(Self.dateLabel)
                        if let e = cal.events.first(where: { ($0.endDate ?? .distantPast) > Date() }) {
                            HStack(spacing: 6) {
                                Capsule().fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(e.title ?? "Event").font(PT.ui(12, 600)).foregroundStyle(NK.ink).lineLimit(1)
                                    NKLabel(e.isAllDay ? "All day" : Self.time.string(from: e.startDate))
                                }
                            }
                        } else {
                            Text(cal.granted ? "Nothing else today" : "Calendar off").font(PT.ui(12, 500)).foregroundStyle(NK.mute)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onTapGesture { model.tab = .calendar }
                TrayMini(controller: controller)
                    .onTapGesture { model.tab = .tray }
            }
        }
    }

    static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static var dateLabel: String { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: Date()) }
}

struct TrayMini: View {
    let controller: NookController
    @EnvironmentObject var shelf: Shelf
    @EnvironmentObject var model: NookModel
    var body: some View {
        NKCard(highlight: model.dropHover) {
            HStack(spacing: 8) {
                if shelf.items.isEmpty {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 13, weight: .semibold)).foregroundStyle(model.dropHover ? PT.accent : NK.mute)
                    NKLabel(model.dropHover ? "Release to keep" : "Drop files here")
                } else {
                    HStack(spacing: -10) {
                        ForEach(shelf.items.suffix(3)) { Thumb(item: $0, size: 24) }
                    }
                    NKLabel("\(PT.n2(shelf.items.count)) in tray")
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MediaCard: View {
    @ObservedObject var media = NowPlaying.shared
    @StateObject private var scrub = ScrubState()

    var body: some View {
        NKCard {
            if media.hasMedia {
                HStack(spacing: 12) {
                    Artwork(size: 76, radius: 12)
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(media.title).font(PT.ui(13, 700)).foregroundStyle(NK.ink).lineLimit(1)
                            Text(media.artist).font(PT.ui(11, 500)).foregroundStyle(NK.mute).lineLimit(1)
                        }
                        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                            let pos = scrub.value ?? media.position(at: ctx.date)
                            VStack(spacing: 3) {
                                ProgressPill(value: media.duration > 0 ? pos / media.duration : 0) { f in
                                    scrub.value = f * media.duration
                                } onEnd: { f in
                                    media.seek(f * media.duration); scrub.value = nil
                                }
                                HStack {
                                    Text(Self.fmt(pos)).font(PT.mono(9)).foregroundStyle(NK.mute)
                                    Spacer()
                                    Text("-" + Self.fmt(max(0, media.duration - pos))).font(PT.mono(9)).foregroundStyle(NK.mute)
                                }
                            }
                        }
                        HStack(spacing: 8) {
                            NKRound(symbol: "backward.fill", help: "Previous") { media.previous() }
                            NKRound(symbol: media.playing ? "pause.fill" : "play.fill", help: "Play/Pause", primary: true) { media.toggle() }
                            NKRound(symbol: "forward.fill", help: "Next") { media.next() }
                            Spacer(minLength: 0)
                            if !media.appName.isEmpty { NKLabel(media.appName) }
                        }
                    }
                }
            } else {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(NK.card2)
                        .frame(width: 76, height: 76)
                        .overlay(Image(systemName: "music.note").font(.system(size: 22, weight: .light)).foregroundStyle(NK.mute))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NO MUSIC").font(PT.dot(18)).tracking(1).foregroundStyle(NK.ink)
                        NKLabel("Play something in Spotify, Music or a browser")
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

struct ProgressPill: View {
    var value: Double
    var onChange: (Double) -> Void
    var onEnd: (Double) -> Void
    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(NK.card2)
                Capsule().fill(NK.ink).frame(width: max(4, w * min(max(value, 0), 1)))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onChange(min(max($0.location.x / w, 0), 1)) }
                .onEnded { onEnd(min(max($0.location.x / w, 0), 1)) })
        }
        .frame(height: 5)
    }
}

struct Artwork: View {
    var size: CGFloat
    var radius: CGFloat
    @ObservedObject var media = NowPlaying.shared
    var body: some View {
        Group {
            if let a = media.art {
                Image(nsImage: a).resizable().aspectRatio(contentMode: .fill)
            } else {
                NK.card2.overlay(Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(NK.mute))
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
    func makeNSView(context: Context) -> EqualizerView { EqualizerView() }
    func updateNSView(_ v: EqualizerView, context: Context) { v.setActive(active) }
}

final class EqualizerView: NSView {
    private var bars: [CALayer] = []
    private var isActive = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for _ in 0..<4 {
            let b = CALayer()
            b.backgroundColor = NSColor(hex: 0xF07A42).cgColor
            b.cornerRadius = 1.5
            layer?.addSublayer(b)
            bars.append(b)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let w: CGFloat = 3, gap: CGFloat = 2, h = bounds.height
        let total = CGFloat(bars.count) * w + CGFloat(bars.count - 1) * gap
        var x = (bounds.width - total) / 2
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for b in bars {
            b.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            b.position = CGPoint(x: x + w / 2, y: h / 2)
            x += w + gap
        }
        CATransaction.commit()
        if isActive { start() }
    }

    func setActive(_ on: Bool) {
        guard on != isActive else { return }
        isActive = on
        on ? start() : stop()
    }

    private func start() {
        for (i, b) in bars.enumerated() {
            b.removeAnimation(forKey: "eq")
            let a = CAKeyframeAnimation(keyPath: "transform.scale.y")
            a.values = [0.35, 1.0, 0.5, 0.85, 0.3, 0.7, 0.35].map { NSNumber(value: $0) }
            a.duration = 0.9 + Double(i) * 0.17
            a.repeatCount = .infinity
            a.autoreverses = true
            a.timeOffset = Double(i) * 0.23
            a.calculationMode = .cubic
            b.add(a, forKey: "eq")
        }
    }

    private func stop() {
        for b in bars {
            b.removeAnimation(forKey: "eq")
            b.transform = CATransform3DMakeScale(1, 0.3, 1)
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
        HStack(spacing: 10) {
            NKCard(highlight: model.dropHover && !model.hoverAirDrop, padding: 8) {
                if shelf.items.isEmpty {
                    ZStack {
                        NKDotGrid(active: model.dropHover && !model.hoverAirDrop)
                        VStack(spacing: 4) {
                            Text("DROP").font(PT.dot(26)).tracking(2)
                                .foregroundStyle(model.dropHover && !model.hoverAirDrop ? PT.accent : NK.ink)
                            NKLabel("Files stay here until you take them")
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(NK.bg))
                    }
                } else {
                    VStack(spacing: 6) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
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
                                }
                            }
                            .padding(2)
                        }
                        HStack(spacing: 6) {
                            NKLabel(shelf.status ?? (shelf.selection.isEmpty ? "\(PT.n2(shelf.items.count)) items · drag out or ⌘-click" : "\(PT.n2(shelf.selection.count)) selected"),
                                    color: shelf.status != nil ? NK.ink : NK.mute)
                            Spacer()
                            NKRound(symbol: "doc.on.clipboard", help: "Paste") { Actions.paste(into: shelf); controller.saveTray() }
                            NKShare(shelf: shelf)
                            NKRound(symbol: "ellipsis", help: "Actions") {
                                let m = ItemMenu.build(for: shelf.targets, controller: controller)
                                m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                            }
                            NKRound(symbol: "trash", help: "Clear tray") { controller.close() }
                        }
                    }
                }
            }
            AirDropZone(hover: model.hoverAirDrop) {
                Actions.send(shelf.targets, via: .sendViaAirDrop, shelf: shelf)
            }
            .frame(width: 132)
        }
        .onChange(of: shelf.items) { _ in controller.saveTray() }
    }

    private func dragSet(_ item: ShelfItem) -> [ShelfItem] {
        shelf.selection.contains(item.id) ? shelf.items.filter { shelf.selection.contains($0.id) } : [item]
    }
    private func click(_ item: ShelfItem, _ mods: NSEvent.ModifierFlags) {
        if mods.contains(.command) || mods.contains(.shift) {
            if shelf.selection.contains(item.id) { shelf.selection.remove(item.id) } else { shelf.selection.insert(item.id) }
        } else {
            shelf.selection = shelf.selection == [item.id] ? [] : [item.id]
        }
        controller.panel.makeKey()
    }
    private func afterDrag(_ items: [ShelfItem], _ op: NSDragOperation) {
        guard op != [] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            shelf.pruneDeadFiles()
            if settings.removeAfterDrag { shelf.remove(Set(items.map(\.id))) }
            controller.saveTray()
        }
    }
}

struct TrayTile: View {
    let item: ShelfItem
    let selected: Bool
    var body: some View {
        VStack(spacing: 5) {
            Thumb(item: item, size: 52)
                .frame(width: 64, height: 58)
            Text(item.title).font(PT.ui(10, 600)).foregroundStyle(selected ? Color.black : NK.ink)
                .lineLimit(1).truncationMode(.middle).frame(width: 70)
        }
        .padding(.horizontal, 4).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? NK.ink : NK.card))
    }
}

struct AirDropZone: View {
    var hover: Bool
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                AirDropGlyph(size: 30).foregroundStyle(hover ? PT.accent : NK.ink)
                Text("AIRDROP").font(PT.mono(9.5)).tracking(1).foregroundStyle(hover ? PT.accent : NK.mute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(hover ? PT.accent.opacity(0.14) : NK.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(hover ? PT.accent : NK.line, style: StrokeStyle(lineWidth: 1, dash: hover ? [] : [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Drop files here to AirDrop · or click to AirDrop the tray")
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

// MARK: Calendar

struct CalendarTab: View {
    @ObservedObject var cal = CalendarModel.shared

    var body: some View {
        HStack(spacing: 10) {
            NKCard {
                VStack(alignment: .leading, spacing: 4) {
                    NKLabel(Self.month.string(from: cal.day))
                    Text(Self.dayNum.string(from: cal.day)).font(PT.dot(46)).foregroundStyle(NK.ink)
                    Text(Self.weekday.string(from: cal.day).uppercased()).font(PT.mono(10)).tracking(1)
                        .foregroundStyle(Calendar.current.isDateInToday(cal.day) ? PT.accent : NK.mute)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        NKRound(symbol: "chevron.left", help: "Previous day") { cal.shift(-1) }
                        NKRound(symbol: "circle.fill", help: "Today") {
                            cal.day = Calendar.current.startOfDay(for: Date()); cal.reload()
                        }
                        NKRound(symbol: "chevron.right", help: "Next day") { cal.shift(1) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .frame(width: 150)

            NKCard {
                if !cal.granted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CALENDAR").font(PT.dot(18)).tracking(1).foregroundStyle(NK.ink)
                        NKLabel("Allow access to show today's events")
                        Button { cal.request() } label: {
                            Text("Allow").font(PT.ui(11, 700)).foregroundStyle(.black)
                                .padding(.horizontal, 14).padding(.vertical, 6)
                                .background(Capsule().fill(PT.accent))
                        }.buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                } else if cal.events.isEmpty {
                    VStack(spacing: 4) {
                        Text("FREE").font(PT.dot(26)).tracking(2).foregroundStyle(NK.ink)
                        NKLabel("No events this day")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(cal.events, id: \.eventIdentifier) { e in
                                let past = (e.endDate ?? .distantFuture) < Date()
                                HStack(spacing: 8) {
                                    Capsule().fill(Color(nsColor: e.calendar.color)).frame(width: 3, height: 26)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(e.title ?? "Event").font(PT.ui(12, 600)).foregroundStyle(past ? NK.mute : NK.ink).lineLimit(1)
                                        NKLabel(e.isAllDay ? "All day" : "\(HomeTab.time.string(from: e.startDate)) – \(HomeTab.time.string(from: e.endDate))")
                                    }
                                    Spacer(minLength: 0)
                                    if let loc = e.location, !loc.isEmpty { NKLabel(loc).frame(maxWidth: 140, alignment: .trailing) }
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                }
            }
        }
    }

    static let month: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f }()
    static let dayNum: DateFormatter = { let f = DateFormatter(); f.dateFormat = "dd"; return f }()
    static let weekday: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE"; return f }()
}

// MARK: Timer + Mirror

struct TimerTab: View {
    @ObservedObject var t = TimerModel.shared
    @ObservedObject var mirror = MirrorModel.shared

    var body: some View {
        HStack(spacing: 10) {
            NKCard {
                HStack(spacing: 16) {
                    ZStack {
                        Circle().stroke(NK.card2, lineWidth: 5)
                        Circle().trim(from: 0, to: t.total > 0 ? t.remaining / t.total : 0)
                            .stroke(t.running ? PT.accent : NK.ink, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text(t.label).font(PT.dot(t.remaining >= 3600 ? 18 : 26)).foregroundStyle(t.finished ? PT.accent : NK.ink)
                    }
                    .frame(width: 112, height: 112)
                    .onScrollWheel { dy in if !t.running { t.nudge(dy > 0 ? 1 : -1) } }
                    .help("Scroll to adjust")

                    VStack(alignment: .leading, spacing: 8) {
                        NKLabel(t.running ? "Running" : (t.finished ? "Done" : "Scroll the dial or pick"))
                        HStack(spacing: 6) {
                            ForEach([5, 15, 25, 45, 60], id: \.self) { m in
                                Button { t.set(minutes: m) } label: {
                                    Text("\(m)").font(PT.mono(10)).foregroundStyle(NK.ink)
                                        .frame(width: 30, height: 24)
                                        .background(Capsule().fill(NK.card2))
                                }.buttonStyle(.plain)
                            }
                        }
                        HStack(spacing: 8) {
                            NKRound(symbol: "minus", help: "−1 min") { t.nudge(-1) }
                            NKRound(symbol: t.running ? "pause.fill" : "play.fill", help: "Start / pause", primary: true) { t.toggle() }
                            NKRound(symbol: "plus", help: "+1 min") { t.nudge(1) }
                            NKRound(symbol: "arrow.counterclockwise", help: "Reset") { t.stop() }
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            NKCard(padding: 0) {
                ZStack {
                    if mirror.running {
                        MirrorPreview(session: mirror.session)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: mirror.denied ? "video.slash" : "person.crop.square")
                                .font(.system(size: 22, weight: .light)).foregroundStyle(NK.mute)
                            Text("MIRROR").font(PT.mono(9.5)).tracking(1).foregroundStyle(NK.mute)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { mirror.running ? mirror.stop() : mirror.start() }
                .help(mirror.denied ? "Camera access is off in System Settings" : "Click for a quick look at yourself")
            }
            .frame(width: 150)
        }
    }
}

/// Scroll-wheel helper (SwiftUI has no scroll-wheel event on macOS 14).
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
        HStack(spacing: 10) {
            NKCard {
                VStack(alignment: .leading, spacing: 6) {
                    NKLabel("Note")
                    TextEditor(text: $n.note)
                        .font(PT.ui(12, 500)).foregroundStyle(NK.ink)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                }
            }
            NKCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Circle().stroke(NK.mute, lineWidth: 1.2).frame(width: 12, height: 12)
                        TextField("Add a to-do, press Return", text: $n.draft, onCommit: { n.add() })
                            .textFieldStyle(.plain).font(PT.ui(12, 500)).foregroundStyle(NK.ink)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 10).fill(NK.card))
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(n.todos) { t in
                                HStack(spacing: 8) {
                                    Button { withAnimation { n.toggle(t) } } label: {
                                        ZStack {
                                            Circle().stroke(t.done ? PT.accent : NK.mute, lineWidth: 1.2)
                                            if t.done { Circle().fill(PT.accent).padding(3) }
                                        }.frame(width: 12, height: 12)
                                    }.buttonStyle(.plain)
                                    Text(t.text).font(PT.ui(12, 500))
                                        .foregroundStyle(t.done ? NK.mute : NK.ink)
                                        .strikethrough(t.done, color: NK.mute).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Button { withAnimation { n.star(t) } } label: {
                                        Image(systemName: t.starred ? "star.fill" : "star").font(.system(size: 10))
                                            .foregroundStyle(t.starred ? PT.accent : NK.mute)
                                    }.buttonStyle(.plain)
                                    Button { withAnimation { n.remove(t) } } label: {
                                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(NK.mute)
                                    }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { controller.panel.makeKey() }
    }
}

// MARK: - Notch-side building blocks (Puteran components, dark)

struct NKCard<Content: View>: View {
    var highlight = false
    var padding: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(highlight ? PT.accent.opacity(0.12) : NK.card))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(highlight ? PT.accent : .clear, lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: highlight)
    }
}

struct NKLabel: View {
    let text: String
    var color: Color = NK.mute
    init(_ t: String, color: Color = NK.mute) { text = t; self.color = color }
    var body: some View { Text(text.uppercased()).font(PT.mono(9)).tracking(0.8).foregroundStyle(color).lineLimit(1) }
}

struct NKRound: View {
    let symbol: String
    var help = ""
    var primary = false
    let action: () -> Void
    @StateObject private var hv = HoverBox()
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: primary ? 12 : 10.5, weight: .semibold))
                .foregroundStyle(primary || hv.on ? Color.black : NK.ink)
                .frame(width: primary ? 30 : 24, height: primary ? 30 : 24)
                .background(Circle().fill(primary ? (hv.on ? PT.accent : NK.ink) : (hv.on ? NK.ink : NK.card2)))
        }
        .buttonStyle(.plain)
        .onHover { hv.on = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.1), value: hv.on)
    }
}

struct NKShare: View {
    @ObservedObject var shelf: Shelf
    var body: some View {
        AnchoredButton(symbol: "square.and.arrow.up", help: "Share") { v in Actions.share(shelf.targets, from: v, rect: v.bounds) }
            .frame(width: 24, height: 24)
            .background(Circle().fill(NK.card2))
    }
}

struct NKDotGrid: View {
    var active: Bool
    var body: some View {
        Canvas { ctx, size in
            let sp: CGFloat = 9
            let cols = Int(size.width / sp), rows = Int(size.height / sp)
            for r in 0..<rows { for c in 0..<cols {
                let p = CGPoint(x: sp / 2 + CGFloat(c) * sp, y: sp / 2 + CGFloat(r) * sp)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.1, y: p.y - 1.1, width: 2.2, height: 2.2)),
                         with: .color(active ? PT.accent.opacity(0.8) : NK.dot))
            } }
        }
    }
}
