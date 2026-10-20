import AppKit

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, symbol: String? = nil, key: String = "", enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: enabled ? #selector(fire) : nil, keyEquivalent: key)
        target = self
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

/// Anything that hosts a Shelf in a window: floating shelves and the notch tray.
protocol ShelfHost: AnyObject {
    var shelf: Shelf { get }
    var hostWindow: NSWindow { get }
    func quickLook()
    func close()
}

enum ItemMenu {
    static func build(for items: [ShelfItem], controller: ShelfHost, includeShelf: Bool = false) -> NSMenu {
        let shelf = controller.shelf
        let menu = NSMenu()
        menu.autoenablesItems = false
        let has = !items.isEmpty
        let files = items.filter { $0.kind == .file }
        let images = items.filter(Actions.isImage)
        let scope = items.count == shelf.items.count ? "All" : "\(items.count) Selected"

        if has {
            let header = NSMenuItem(title: "\(scope) · \(items.count) item\(items.count == 1 ? "" : "s")", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        menu.addItem(ClosureMenuItem("Open", symbol: "arrow.up.forward.app", enabled: has) { Actions.open(items) })
        menu.addItem(ClosureMenuItem("Quick Look", symbol: "eye", enabled: !files.isEmpty) { controller.quickLook() })
        menu.addItem(ClosureMenuItem("Show in Finder", symbol: "folder", enabled: !files.isEmpty) { Actions.reveal(items) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Copy", symbol: "doc.on.doc", enabled: has) { Actions.copy(items, shelf: shelf) })
        menu.addItem(ClosureMenuItem("Copy Path", symbol: "link", enabled: has) { Actions.copyPaths(items, shelf: shelf) })
        menu.addItem(ClosureMenuItem("Save to Folder…", symbol: "square.and.arrow.down", enabled: !files.isEmpty) {
            Actions.saveTo(items, shelf: shelf, move: false)
        })
        menu.addItem(ClosureMenuItem("Move to Folder…", symbol: "arrow.right.doc.on.clipboard", enabled: !files.isEmpty) {
            Actions.saveTo(items, shelf: shelf, move: true)
        })
        menu.addItem(.separator())

        // Share
        let shareMenu = NSMenu()
        shareMenu.autoenablesItems = false
        let services: [(String, NSSharingService.Name)] = [("AirDrop", .sendViaAirDrop),
                                                           ("Messages", .composeMessage),
                                                           ("Mail", .composeEmail)]
        for (title, name) in services {
            let it = ClosureMenuItem(title, enabled: has) { Actions.send(items, via: name, shelf: shelf) }
            it.image = NSSharingService(named: name)?.image
            shareMenu.addItem(it)
        }
        shareMenu.addItem(.separator())
        shareMenu.addItem(ClosureMenuItem("More…", symbol: "ellipsis.circle", enabled: has) {
            guard let v = controller.hostWindow.contentView else { return }
            let p = v.convert(controller.hostWindow.mouseLocationOutsideOfEventStream, from: nil)
            Actions.share(items, from: v, rect: NSRect(x: p.x, y: p.y, width: 1, height: 1))
        })
        let shareItem = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        shareItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        shareItem.submenu = shareMenu
        shareItem.isEnabled = has
        menu.addItem(shareItem)
        let airdrop = ClosureMenuItem("AirDrop", enabled: has) { Actions.send(items, via: .sendViaAirDrop, shelf: shelf) }
        if let g = AirDropIcon.template?.copy() as? NSImage { g.size = NSSize(width: 15, height: 15); airdrop.image = g }
        menu.addItem(airdrop)
        menu.addItem(.separator())

        // File actions
        menu.addItem(ClosureMenuItem("Create ZIP", symbol: "doc.zipper", enabled: !files.isEmpty) { Actions.zip(items, shelf: shelf) })

        let imageMenu = NSMenu()
        imageMenu.autoenablesItems = false
        for side in [3840, 2048, 1080, 512] {
            imageMenu.addItem(ClosureMenuItem("Resize to \(side) px") {
                Actions.processImages(items, shelf: shelf, maxSide: CGFloat(side))
            })
        }
        imageMenu.addItem(ClosureMenuItem("Resize to 50%") { Actions.processImages(items, shelf: shelf, scale: 0.5) })
        imageMenu.addItem(.separator())
        imageMenu.addItem(ClosureMenuItem("Convert to PNG") { Actions.processImages(items, shelf: shelf, format: .png) })
        imageMenu.addItem(ClosureMenuItem("Convert to JPG") { Actions.processImages(items, shelf: shelf, format: .jpg) })
        imageMenu.addItem(.separator())
        imageMenu.addItem(ClosureMenuItem("Extract Text (OCR)") { Actions.extractText(items, shelf: shelf) })
        let imageItem = NSMenuItem(title: "Image", action: nil, keyEquivalent: "")
        imageItem.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        imageItem.submenu = imageMenu
        imageItem.isEnabled = !images.isEmpty
        menu.addItem(imageItem)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Remove from Shelf", symbol: "minus.circle", enabled: has) {
            shelf.remove(Set(items.map(\.id)))
        })

        if includeShelf {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem("Paste", symbol: "doc.on.clipboard") { Actions.paste(into: shelf) })
            menu.addItem(ClosureMenuItem("Rename Shelf…", symbol: "pencil") {
                controller.hostWindow.makeKey(); shelf.renaming = true
            })
            let colorMenu = NSMenu()
            for (i, name) in Shelf.colorNames.enumerated() {
                let it = ClosureMenuItem(name) { shelf.colorIndex = i }
                it.state = shelf.colorIndex == i ? .on : .off
                if i > 0 { it.image = swatch(NSColor(Shelf.colors[i])) }
                colorMenu.addItem(it)
            }
            let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
            colorItem.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
            colorItem.submenu = colorMenu
            menu.addItem(colorItem)
            menu.addItem(ClosureMenuItem("Clear Shelf", symbol: "trash", enabled: !shelf.items.isEmpty) {
                shelf.remove(Set(shelf.items.map(\.id)))
            })
            menu.addItem(ClosureMenuItem("Close Shelf", symbol: "xmark") { controller.close() })
        }
        return menu
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in
            color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true
        }
    }
}
