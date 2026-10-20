import AppKit
import SwiftUI

/// AppKit view that lets SwiftUI content act as a drag source for MANY items at once
/// (SwiftUI's .onDrag only supports one), plus click / double-click / context menu.
struct DragSource: NSViewRepresentable {
    var items: () -> [ShelfItem]
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var menu: () -> NSMenu? = { nil }
    var onEnded: (NSDragOperation) -> Void = { _ in }

    func makeNSView(context: Context) -> DragSourceNSView { DragSourceNSView() }

    func updateNSView(_ v: DragSourceNSView, context: Context) {
        v.items = items
        v.onClick = onClick
        v.onDoubleClick = onDoubleClick
        v.menuProvider = menu
        v.onEnded = onEnded
    }
}

final class DragSourceNSView: NSView, NSDraggingSource {
    /// True while any shelf/tray item is being dragged out (keeps the notch from collapsing mid-drag).
    static var isDraggingOut = false

    var items: () -> [ShelfItem] = { [] }
    var onClick: (NSEvent.ModifierFlags) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}
    var menuProvider: () -> NSMenu? = { nil }
    var onEnded: (NSDragOperation) -> Void = { _ in }

    private var downEvent: NSEvent?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        dragging = false
        if event.clickCount == 2 { onDoubleClick(); downEvent = nil }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent, !dragging else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        let list = items()
        guard !list.isEmpty else { return }
        dragging = true
        DragSourceNSView.isDraggingOut = true
        let origin = convert(down.locationInWindow, from: nil)
        let draggingItems: [NSDraggingItem] = list.enumerated().map { i, item in
            let d = NSDraggingItem(pasteboardWriter: item.pasteboardWriter())
            let icon = ThumbnailCache.shared.cached(item) ?? item.fallbackIcon
            let size: CGFloat = 64
            let off = CGFloat(min(i, 4)) * 4
            d.setDraggingFrame(NSRect(x: origin.x - size / 2 + off, y: origin.y - size / 2 - off,
                                      width: size, height: size), contents: icon)
            return d
        }
        let session = beginDraggingSession(with: draggingItems, event: down, source: self)
        session.draggingFormation = list.count > 1 ? .pile : .none
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        if downEvent != nil, !dragging { onClick(event.modifierFlags) }
        downEvent = nil
    }

    override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .link, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        dragging = false
        downEvent = nil
        DragSourceNSView.isDraggingOut = false
        onEnded(operation)
    }
}
