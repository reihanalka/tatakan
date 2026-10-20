import AppKit

/// Reports share results back to the shelf ("Sent via AirDrop" / "Share failed").
final class ShareRelay: NSObject, NSSharingServiceDelegate {
    static let shared = ShareRelay()
    private var shelves: [ObjectIdentifier: Shelf] = [:]

    func attach(_ service: NSSharingService, shelf: Shelf) {
        shelves[ObjectIdentifier(service)] = shelf
        service.delegate = self
        shelf.status = "Sharing…"
    }

    func sharingService(_ s: NSSharingService, didShareItems items: [Any]) {
        guard let shelf = shelves.removeValue(forKey: ObjectIdentifier(s)) else { return }
        shelf.toast("Sent · \(s.title)")
    }

    func sharingService(_ s: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        guard let shelf = shelves.removeValue(forKey: ObjectIdentifier(s)) else { return }
        // User closing the AirDrop window counts as a "failure" — keep it quiet.
        let cancelled = (error as NSError).code == NSUserCancelledError
        if cancelled { shelf.status = nil } else { shelf.toast("Share failed") }
    }
}
