import AppKit
import SwiftUI
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var shelves: [ShelfController] = []
    private let shake = ShakeDetector()
    private var hotKey: HotKey?
    private var settingsWindow: NSWindow?
    private var nook: NookController?
    private var nookKey: HotKey?

    func applicationDidFinishLaunching(_ n: Notification) {
        PT.registerFonts()
        setupStatusItem()
        shake.onShake = { [weak self] p in self?.newShelf(at: p) }
        shake.start()
        hotKey = HotKey(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.newShelf(at: nil)?.panel.makeKey()
        }
        cleanOldCache()
        setupNook()
        nookKey = HotKey(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(controlKey | optionKey), id: 2) { [weak self] in
            guard let n = self?.nook else { return }
            n.model.state == .open ? n.set(.closed) : n.open(tab: n.model.tab)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.placeNook()
        }
        NotificationCenter.default.addObserver(forName: .tatakanNotchToggled, object: nil, queue: .main) { [weak self] _ in
            self?.setupNook()
        }
        if CommandLine.arguments.contains("--light") { NSApp.appearance = NSAppearance(named: .aqua) }
        if CommandLine.arguments.contains("--demo") { demo() }
    }

    // MARK: Notch
    /// The screen with a notch, else the main (menu-bar) screen.
    private var nookScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.screens.first
    }

    private func setupNook() {
        guard Settings.shared.notchEnabled else {
            nook?.panel.orderOut(nil); nook = nil
            NowPlaying.shared.stop()
            return
        }
        guard nook == nil, let s = nookScreen else { return }
        let n = NookController(screen: s)
        n.loadTray()
        nook = n
        NowPlaying.shared.start()
        LiveActivities.shared.start()
    }

    private func placeNook() {
        guard let n = nook, let s = nookScreen else { return }
        n.reposition(to: s)
    }

    @objc func openSettingsAction() { openSettings() }

    // MARK: Menu bar
    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let b = statusItem.button {
            let icon = Bundle.main.url(forResource: "menubar", withExtension: "png", subdirectory: "Icons")
                .flatMap { NSImage(contentsOf: $0) }
                ?? NSImage(systemSymbolName: "square.stack.3d.down.right.fill", accessibilityDescription: "Tatakan")
            icon?.size = NSSize(width: 15, height: 15)   // same as Puteran
            icon?.isTemplate = true
            b.image = icon
            // Drop files on the menu bar icon → new shelf (NSWindow forwards drag calls to its delegate).
            b.window?.registerForDraggedTypes(Ingest.draggedTypes)
            b.window?.delegate = self
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("New Shelf", symbol: "plus.rectangle.on.rectangle") { [weak self] in
            self?.newShelf(at: nil)?.panel.makeKey()
        })
        menu.addItem(ClosureMenuItem("New Shelf from Clipboard", symbol: "doc.on.clipboard") { [weak self] in
            guard let c = self?.newShelf(at: nil) else { return }
            Actions.paste(into: c.shelf)
        })
        if let n = nook {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Open Nook", symbol: "rectangle.topthird.inset.filled") { n.open(tab: .home) })
            let trayTitle = n.shelf.items.isEmpty ? "Notch Tray" : "Notch Tray — \(n.shelf.items.count)"
            menu.addItem(ClosureMenuItem(trayTitle, symbol: "tray") { n.open(tab: .tray) })
        }

        if !shelves.isEmpty {
            menu.addItem(.separator())
            let h = NSMenuItem(title: "Open Shelves", action: nil, keyEquivalent: ""); h.isEnabled = false
            menu.addItem(h)
            for c in shelves {
                menu.addItem(ClosureMenuItem(c.shelf.displayTitle, symbol: "tray") {
                    c.panel.orderFrontRegardless(); c.panel.makeKey()
                })
            }
            menu.addItem(ClosureMenuItem("Close All Shelves", symbol: "xmark.square") { [weak self] in
                self?.shelves.forEach { $0.close() }
            })
        }

        let recent = Settings.shared.recent
        let recentMenu = NSMenu()
        recentMenu.autoenablesItems = false
        let fmt = RelativeDateTimeFormatter(); fmt.unitsStyle = .short
        for snap in recent {
            let it = ClosureMenuItem("\(snap.title) — \(fmt.localizedString(for: snap.closedAt, relativeTo: Date()))") { [weak self] in
                self?.restore(snap)
            }
            if snap.colorIndex > 0 { it.image = ItemMenu.swatch(NSColor(Shelf.colors[snap.colorIndex])) }
            recentMenu.addItem(it)
        }
        if !recent.isEmpty {
            recentMenu.addItem(.separator())
            recentMenu.addItem(ClosureMenuItem("Clear Recent") { Settings.shared.recent = [] })
        }
        let recentItem = NSMenuItem(title: "Recent Shelves", action: nil, keyEquivalent: "")
        recentItem.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        recentItem.submenu = recentMenu
        recentItem.isEnabled = !recent.isEmpty
        menu.addItem(.separator())
        menu.addItem(recentItem)

        menu.addItem(.separator())
        let shakeItem = ClosureMenuItem("Shake to Open") { Settings.shared.shakeEnabled.toggle() }
        shakeItem.state = Settings.shared.shakeEnabled ? .on : .off
        menu.addItem(shakeItem)
        menu.addItem(ClosureMenuItem("Settings…", key: ",") { [weak self] in self?.openSettings() })
        menu.addItem(ClosureMenuItem("Quit Tatakan", key: "q") { NSApp.terminate(nil) })
    }

    // Status item drop target
    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        statusItem.button?.highlight(true); return .copy
    }
    func draggingExited(_ sender: NSDraggingInfo?) { statusItem.button?.highlight(false) }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        statusItem.button?.highlight(false)
        var p = NSEvent.mouseLocation
        p.y -= 30
        guard let c = newShelf(at: p) else { return false }
        return c.accept(sender.draggingPasteboard)
    }

    // MARK: Shelves
    @discardableResult
    func newShelf(at point: NSPoint?) -> ShelfController? {
        // Reuse an empty shelf instead of stacking empties.
        if let empty = shelves.first(where: { $0.shelf.items.isEmpty }) {
            empty.panel.orderFrontRegardless()
            return empty
        }
        let c = ShelfController(at: point)
        c.onClose = { [weak self] closed in
            guard let self else { return }
            if !closed.shelf.items.isEmpty {
                var r = Settings.shared.recent
                r.insert(closed.shelf.snapshot, at: 0)
                Settings.shared.recent = r
            }
            self.shelves.removeAll { $0 === closed }
        }
        shelves.append(c)
        c.show()
        return c
    }

    private func restore(_ snap: Shelf.Snapshot) {
        let c = ShelfController(at: nil)
        c.shelf.name = snap.name
        c.shelf.colorIndex = snap.colorIndex
        c.shelf.items = snap.items.filter(\.isAlive)
        c.onClose = { [weak self] closed in
            if !closed.shelf.items.isEmpty {
                var r = Settings.shared.recent; r.insert(closed.shelf.snapshot, at: 0); Settings.shared.recent = r
            }
            self?.shelves.removeAll { $0 === closed }
        }
        Settings.shared.recent = Settings.shared.recent.filter { $0.id != snap.id }
        shelves.append(c)
        c.show()
        c.panel.makeKey()
    }

    // MARK: Settings window
    private func openSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView()))
            w.title = "Tatakan Settings"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Temp files (zips, resized images, browser images) older than 3 days.
    private func cleanOldCache() {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: Ingest.cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let limit = Date().addingTimeInterval(-3 * 86400)
        for d in dirs {
            let date = (try? d.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            if date < limit { try? fm.removeItem(at: d) }
        }
    }

    // Used for screenshots/testing: `Tatakan --demo <file> <file> … [--expand]`
    private func demo() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--demo") else { return }
        let files = args[(i + 1)...].filter { !$0.hasPrefix("--") }.map { URL(fileURLWithPath: $0) }
        let c = newShelf(at: NSPoint(x: 400, y: 600))
        c?.shelf.add(files.map(ShelfItem.file))
        if args.contains("--expand") { c?.setExpanded(true) }
        if let t = args.firstIndex(of: "--nook"), let n = nook {
            if args.contains("--dragsim") {           // same order as a real drag: hover → open
                c?.close()
                n.shelf.add(files.map(ShelfItem.file))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { n.dragEntered() }
                return
            }
            let name = args.indices.contains(t + 1) ? args[t + 1] : "home"
            let tab = ["home": NookTab.home, "tray": .tray, "cal": .calendar, "timer": .timer, "notes": .notes][name] ?? .home
            c?.close()
            n.shelf.add(files.map(ShelfItem.file))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                n.open(tab: tab)
                if args.contains("--drophover") { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { n.model.dropHover = true } }
                if args.contains("--airdrophover") { n.model.dropHover = true; n.model.hoverAirDrop = true }
            }
        }
        if args.contains("--activity") {
            c?.close()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                LiveActivities.shared.show(LiveActivity(symbol: "bolt.fill", left: "Charging", right: "86%", accent: true), seconds: 30)
            }
        }
        if args.contains("--hover-test"), let c { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { c.panel.makeKey() } }
        if args.contains("--pair") {
            let e = ShelfController(at: NSPoint(x: 700, y: 600))
            shelves.append(e); e.show()
            let l = ShelfController(at: NSPoint(x: 1000, y: 600))
            l.shelf.add(files.map(ShelfItem.file)); l.shelf.add([.text("Brief klien v2 — revisi warna")])
            l.shelf.name = "Revisi KV"; l.shelf.colorIndex = 2
            shelves.append(l); l.show(); l.setExpanded(true)
            l.shelf.selection = [l.shelf.items[1].id]
        }
    }
}
