import AppKit
import SwiftUI
import QuickLookUI

// MARK: - Window

/// Floating, non-activating panel that hosts one shelf.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Root content view: accepts drops for the whole window.
final class DropContainer: NSView {
    weak var controller: ShelfController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(Ingest.draggedTypes)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Ignore drags that started on this same shelf.
        if let src = sender.draggingSource as? NSView, src.window === window { return [] }
        controller?.shelf.isTargeted = true
        return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if let src = sender.draggingSource as? NSView, src.window === window { return [] }
        return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { controller?.shelf.isTargeted = false }
    override func draggingEnded(_ sender: NSDraggingInfo) { controller?.shelf.isTargeted = false }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.shelf.isTargeted = false
        return controller?.accept(sender.draggingPasteboard) ?? false
    }
}

final class ShelfController: NSObject, NSWindowDelegate, QLPreviewPanelDataSource, QLPreviewPanelDelegate, ShelfHost {
    let shelf = Shelf()
    let glow = GlowDriver()
    let panel: ShelfPanel
    var hostWindow: NSWindow { panel }
    private let container: DropContainer
    var onClose: ((ShelfController) -> Void)?
    private var keyMonitor: Any?
    private var previewItems: [URL] = []

    static let collapsedSize = NSSize(width: 196, height: 236)
    static let expandedSize = NSSize(width: 300, height: 420)

    init(at point: NSPoint?) {
        let size = ShelfController.collapsedSize
        panel = ShelfPanel(contentRect: NSRect(origin: .zero, size: size),
                           styleMask: [.borderless, .nonactivatingPanel, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        container = DropContainer(frame: NSRect(origin: .zero, size: size))
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 170, height: 190)
        panel.delegate = self
        panel.animationBehavior = .utilityWindow
        panel.appearance = NSAppearance(named: .darkAqua)   // black → clear glass surface, same as the Nook

        container.controller = self
        let host = NSHostingView(rootView: ShelfView(controller: self, glow: glow).environmentObject(shelf))
        host.sizingOptions = []   // window frame is ours (collapse/expand); see NookController
        host.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.topAnchor.constraint(equalTo: container.topAnchor),
            host.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container

        position(near: point)
        installKeys()
    }

    private func position(near point: NSPoint?) {
        let p = point ?? NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        let s = panel.frame.size
        var origin = NSPoint(x: p.x + 24, y: p.y - s.height / 2)
        if origin.x + s.width > vf.maxX { origin.x = p.x - s.width - 24 }
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - s.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - s.height - 8)
        panel.setFrameOrigin(origin)
    }

    func show() {
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        glow.glassAfter(0.32)
        glow.reveal()
        glow.burst()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; panel.animator().alphaValue = 1 }
    }

    func close() {
        glow.reset()
        glow.glassOff()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.14; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            if let m = self.keyMonitor { NSEvent.removeMonitor(m) }
            self.onClose?(self)
        })
    }

    @discardableResult
    func accept(_ pb: NSPasteboard) -> Bool {
        let r = Ingest.items(from: pb)
        shelf.add(r.items)
        if !r.promises.isEmpty {
            shelf.status = "Receiving…"
            let dir = Ingest.newTempFolder()
            let queue = OperationQueue()
            for promise in r.promises {
                promise.receivePromisedFiles(atDestination: dir, options: [:], operationQueue: queue) { [weak self] url, error in
                    DispatchQueue.main.async {
                        if error == nil { self?.shelf.add([.file(url)]) }
                        self?.shelf.status = nil
                    }
                }
            }
        }
        if !r.items.isEmpty || !r.promises.isEmpty {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            return true
        }
        return false
    }

    func setExpanded(_ on: Bool) {
        guard shelf.expanded != on else { return }
        let target = on ? ShelfController.expandedSize : ShelfController.collapsedSize
        var f = panel.frame
        let top = f.maxY
        f.size = target
        f.origin.y = top - target.height
        if let vf = panel.screen?.visibleFrame {
            f.origin.x = min(max(f.origin.x, vf.minX + 8), vf.maxX - f.width - 8)
            f.origin.y = max(f.origin.y, vf.minY + 8)
        }
        withAnimation(Motion.settle) { shelf.expanded = on }
        panel.setFrame(f, display: true, animate: true)
        if !on { shelf.selection = [] }
    }

    // MARK: Keyboard (when the shelf is focused)
    private func installKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.panel, !self.shelf.renaming else { return e }
            let cmd = e.modifierFlags.contains(.command)
            switch (e.keyCode, cmd, e.charactersIgnoringModifiers ?? "") {
            case (49, false, _): self.quickLook(); return nil                    // space
            case (51, _, _), (117, _, _):                                         // delete
                let ids = self.shelf.selection.isEmpty ? Set(self.shelf.items.map(\.id)) : self.shelf.selection
                self.shelf.remove(ids); return nil
            case (53, false, _): self.close(); return nil                         // esc
            case (_, true, "c"): Actions.copy(self.shelf.targets, shelf: self.shelf); return nil
            case (_, true, "v"): Actions.paste(into: self.shelf); return nil
            case (_, true, "A") where e.modifierFlags.contains(.shift):
                Actions.send(self.shelf.targets, via: .sendViaAirDrop, shelf: self.shelf); return nil
            case (_, true, "a"): self.setExpanded(true); self.shelf.selection = Set(self.shelf.items.map(\.id)); return nil
            case (_, true, "w"): self.close(); return nil
            case (_, true, "o"): Actions.open(self.shelf.targets); return nil
            default: return e
            }
        }
    }

    // MARK: Quick Look
    func quickLook() {
        previewItems = shelf.targets.compactMap { $0.kind == .file ? $0.url : nil }
        guard !previewItems.isEmpty, let ql = QLPreviewPanel.shared() else { return }
        panel.makeKey()
        ql.dataSource = self
        ql.delegate = self
        ql.reloadData()
        if ql.isVisible { ql.orderOut(nil) } else { ql.makeKeyAndOrderFront(nil) }
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewItems.count }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewItems[index] as NSURL
    }

    // MARK: Window delegate
    func windowDidBecomeKey(_ notification: Notification) { shelf.pruneDeadFiles() }
}

// MARK: - SwiftUI view
// Visual language: Puteran (Space Grotesk / Space Mono / Doto, ink controls, one accent)
// laid over a translucent "smoke" blur so the desktop shows through.

struct ShelfView: View {
    let controller: ShelfController
    @ObservedObject var glow: GlowDriver
    @EnvironmentObject var shelf: Shelf
    @ObservedObject var settings = Settings.shared
    private let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            header
            ZStack {
                if shelf.items.isEmpty { emptyState }
                else if shelf.expanded { listView }
                else { pileView }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background {
            ZStack {
                LiquidSurface(shape: shape, glass: glow.glassReady, topAlpha: 0.9, veil: glow.glassReady ? 0 : 0.82)
                AIBloom(driver: glow).mask(shape)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(PT.smokeLine, lineWidth: 1))
        .overlay {
            // Drop target: Siri edge light; plain accent ring if the glow is switched off.
            if shelf.isTargeted && !settings.aiGlow { shape.strokeBorder(PT.accent, lineWidth: 1.5) }
        }
        .overlay(AIGlowRim(shape: shape, driver: glow))
        .scaleEffect(glow.revealed ? 1 : 0.86)
        .opacity(glow.revealed ? 1 : 0)
        .blur(radius: glow.revealed ? 0 : 18)
        .animation(.easeOut(duration: 0.45), value: glow.revealed)   // blur clears slower than the scale lands
        .environment(\.colorScheme, .dark)
        .environment(\.controlActiveState, .key)    // same as the Nook: always look active
        .onChange(of: shelf.isTargeted) { _, on in glow.hold(on) }
        .animation(.easeOut(duration: 0.12), value: shelf.isTargeted)
    }

    // Header: close · title + meta · menu
    private var header: some View {
        HStack(alignment: .center, spacing: 6) {
            RoundIcon(symbol: "xmark", help: "Close Shelf (⌘W)") { controller.close() }
            Spacer(minLength: 0)
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    if let tint = shelf.tint { Circle().fill(tint).frame(width: 6, height: 6) }
                    if shelf.renaming {
                        TextField("Shelf name", text: $shelf.name, onCommit: { shelf.renaming = false })
                            .textFieldStyle(.plain).font(PT.ui(12, 700))
                            .multilineTextAlignment(.center).frame(maxWidth: 130)
                    } else {
                        Text(shelf.name.isEmpty ? "Shelf" : shelf.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(PT.ink).lineLimit(1)
                            .onTapGesture(count: 2) { shelf.renaming = true }
                    }
                }
                Label9(meta)
            }
            Spacer(minLength: 0)
            MenuButton(controller: controller)
        }
        .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 6)
    }

    private var meta: String {
        if shelf.items.isEmpty { return "Empty" }
        let bytes = shelf.items.reduce(Int64(0)) { sum, i in
            guard i.kind == .file, let u = i.url else { return sum }
            return sum + FileMeta.of(u).size
        }
        let n = "\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s")"
        return bytes > 0 && shelf.expanded ? n + " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : n
    }

    private var emptyState: some View {
        DropZone(active: shelf.isTargeted, title: "Drop here", subtitle: "Files, links or text")
            .padding(.horizontal, 10).padding(.bottom, 2)
    }

    // Collapsed: a pile of thumbnails on a card; drag it to drag everything.
    private var pileView: some View {
        let top = Array(shelf.items.suffix(3))
        return ZStack {
            ForEach(Array(top.enumerated()), id: \.element.id) { i, item in
                let depth = CGFloat(top.count - 1 - i)
                Thumb(item: item, size: 84)
                    .shadow(color: .black.opacity(0.22), radius: 4, y: 2)
                    .rotationEffect(.degrees(Double(depth) * (i % 2 == 0 ? -6 : 6)))
                    .offset(y: -depth * 4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if shelf.items.count > 1 {
                Text("\(shelf.items.count)").font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(PT.accent))
                    .padding(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(PT.smokeCard))
        .contentShape(Rectangle())
        .overlay(
            DragSource(items: { shelf.items },
                       onClick: { _ in controller.setExpanded(true) },
                       onDoubleClick: { Actions.open(shelf.items) },
                       menu: { ItemMenu.build(for: shelf.items, controller: controller) },
                       onEnded: { op in afterDrag(shelf.items, op) })
        )
        .padding(.horizontal, 10).padding(.bottom, 2)
        .help("Drag to drop everything · Click to see items")
    }

    // Expanded: list with selection.
    private var listView: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(shelf.items) { item in
                    ItemRow(item: item, selected: shelf.selection.contains(item.id))
                        .overlay(
                            DragSource(items: { dragSet(for: item) },
                                       onClick: { mods in click(item, mods) },
                                       onDoubleClick: { Actions.open([item]) },
                                       menu: {
                                           if !shelf.selection.contains(item.id) { shelf.selection = [item.id] }
                                           return ItemMenu.build(for: shelf.targets, controller: controller)
                                       },
                                       onEnded: { op in afterDrag(dragSet(for: item), op) })
                        )
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if shelf.expanded {
                RoundIcon(symbol: "square.stack", help: "Collapse") { controller.setExpanded(false) }
            } else {
                RoundIcon(symbol: "list.bullet", help: "Show items") { controller.setExpanded(true) }
                    .disabled(shelf.items.isEmpty)
            }
            Spacer(minLength: 0)
            if let s = shelf.status {
                HStack(spacing: 5) {
                    Circle().fill(PT.accent).frame(width: 5, height: 5)
                    Label9(s, color: PT.ink)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(PT.smokeCard))
                .transition(.opacity)
                Spacer(minLength: 0)
            }
            AirDropButton(shelf: shelf)
            ShareButton(shelf: shelf)
            RoundIcon(symbol: "doc.on.clipboard", help: "Paste (⌘V)") { Actions.paste(into: shelf) }
        }
        .padding(.horizontal, 10).padding(.bottom, 10).padding(.top, 8)
        .animation(.easeOut(duration: 0.15), value: shelf.status)
    }

    private func dragSet(for item: ShelfItem) -> [ShelfItem] {
        shelf.selection.contains(item.id) ? shelf.items.filter { shelf.selection.contains($0.id) } : [item]
    }

    private func click(_ item: ShelfItem, _ mods: NSEvent.ModifierFlags) {
        if mods.contains(.command) {
            if shelf.selection.contains(item.id) { shelf.selection.remove(item.id) } else { shelf.selection.insert(item.id) }
        } else if mods.contains(.shift), let last = shelf.selection.first,
                  let a = shelf.items.firstIndex(where: { $0.id == last }),
                  let b = shelf.items.firstIndex(where: { $0.id == item.id }) {
            shelf.selection = Set(shelf.items[min(a, b)...max(a, b)].map(\.id))
        } else {
            shelf.selection = [item.id]
        }
        controller.panel.makeKey()
    }

    /// After a successful drop elsewhere: optionally clear what was dragged out.
    private func afterDrag(_ items: [ShelfItem], _ op: NSDragOperation) {
        guard op != [] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            shelf.pruneDeadFiles()   // a Finder "move" leaves nothing behind
            if settings.removeAfterDrag { shelf.remove(Set(items.map(\.id))) }
            if settings.closeWhenEmpty && shelf.items.isEmpty { controller.close() }
        }
    }
}

struct ItemRow: View {
    let item: ShelfItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 9) {
            Thumb(item: item, size: 30)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(PT.smoke.opacity(selected ? 0 : 1)))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(PT.ui(12, 600)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(PT.ink)
                Label9(subtitle, color: selected ? Color.white.opacity(0.75) : PT.mute)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? PT.accent : Color.white.opacity(0.06)))
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        switch item.kind {
        case .link: return "Link · " + (item.url?.host ?? "")
        case .text: return "Text · \(item.text?.count ?? 0) chr"
        case .file:
            guard let url = item.url else { return "" }
            let m = FileMeta.of(url)
            if m.dir { return "Folder" }
            let ext = url.pathExtension.isEmpty ? "File" : url.pathExtension
            let size = ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file)
            return "\(ext) · \(size)"
        }
    }
}

// MARK: - Small controls (Puteran RoundIcon)

final class HoverBox: ObservableObject { @Published var on = false }

struct RoundIcon: View {
    let symbol: String
    var help: String = ""
    let action: () -> Void
    @StateObject private var hv = HoverBox()

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PT.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hv.on ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(Motion.quick) { hv.on = h } }
        .help(help)
    }
}

struct MenuButton: View {
    let controller: ShelfController
    var body: some View {
        AnchoredButton(symbol: "ellipsis", help: "Actions") { view in
            let menu = ItemMenu.build(for: controller.shelf.targets, controller: controller, includeShelf: true)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        }
        .roundChrome()
    }
}

/// One-click AirDrop for the selection (or the whole shelf). Uses the system AirDrop glyph.
struct AirDropButton: View {
    @ObservedObject var shelf: Shelf
    @StateObject private var hv = HoverBox()
    var body: some View {
        Button { Actions.send(shelf.targets, via: .sendViaAirDrop, shelf: shelf) } label: {
            AirDropGlyph(size: 14)
                .foregroundStyle(PT.ink)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(hv.on ? 0.2 : 0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressScale())
        .onHover { h in withAnimation(Motion.quick) { hv.on = h } }
        .help("AirDrop")
        .disabled(shelf.items.isEmpty)
    }
}

/// The real AirDrop glyph (Finder sidebar icon from macOS), tinted like our other icons.
enum AirDropIcon {
    static let template: NSImage? = {
        let path = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/SidebarAirDrop.icns"
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        img.isTemplate = true
        return img
    }()
}

struct AirDropGlyph: View {
    var size: CGFloat
    var body: some View {
        if let img = AirDropIcon.template {
            Image(nsImage: img).renderingMode(.template).resizable().interpolation(.high)
                .scaledToFit().frame(width: size, height: size)
        } else {
            Image(systemName: "dot.radiowaves.up.forward").font(.system(size: 11, weight: .semibold))
        }
    }
}

struct ShareButton: View {
    @ObservedObject var shelf: Shelf
    var body: some View {
        AnchoredButton(symbol: "square.and.arrow.up", help: "Share") { view in
            Actions.share(shelf.targets, from: view, rect: view.bounds)
        }
        .roundChrome()
        .disabled(shelf.items.isEmpty)
    }
}

extension View {
    func roundChrome() -> some View {
        frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(0.1)))
    }
}

/// Button that gives its action a backing NSView (needed for menus & share pickers).
/// SwiftUI button + an inert anchor view. It used to be an NSButton inside SwiftUI: on macOS 27 the
/// button re-laid out its image view on every pass, which invalidated SwiftUI layout again, until
/// AppKit threw "more Update Constraints passes than views" and the app crashed.
struct AnchoredButton: View {
    let symbol: String
    var help: String
    let action: (NSView) -> Void
    @StateObject private var anchor = AnchorBox()

    var body: some View {
        Button { if let v = anchor.view { action(v) } } label: {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PT.ink)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .background(AnchorView(box: anchor))
    }
}

final class AnchorBox: ObservableObject { weak var view: NSView? }

struct AnchorView: NSViewRepresentable {
    let box: AnchorBox
    /// Flipped like NSControl, so menu offsets written for the old NSButton still land below it.
    final class V: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
    func makeNSView(context: Context) -> V { let v = V(); box.view = v; return v }
    func updateNSView(_ v: V, context: Context) { box.view = v }
}

/// The "smoke": live blur of whatever is behind the shelf.
struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}
