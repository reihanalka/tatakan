import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Small async thumbnail cache backed by Quick Look.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var store: [UUID: NSImage] = [:]

    func cached(_ item: ShelfItem) -> NSImage? { store[item.id] }

    func load(_ item: ShelfItem, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        if let img = store[item.id] { completion(img); return }
        guard item.kind == .file, let url = item.url else { completion(item.fallbackIcon); return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                               scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            DispatchQueue.main.async {
                let img = rep?.nsImage ?? item.fallbackIcon
                self?.store[item.id] = img
                completion(img)
            }
        }
    }
}

final class ImageBox: ObservableObject { @Published var image: NSImage? }

struct Thumb: View {
    let item: ShelfItem
    var size: CGFloat
    @StateObject private var box = ImageBox()

    var body: some View {
        Group {
            if let image = box.image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: item.fallbackIcon).resizable().aspectRatio(contentMode: .fit).opacity(0.4)
            }
        }
        .frame(width: size, height: size)
        .onAppear { ThumbnailCache.shared.load(item, size: size * 2) { box.image = $0 } }
    }
}
