import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Small async thumbnail cache backed by Quick Look.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    /// Bounded (was an ever-growing dictionary for the life of the app).
    private let store: NSCache<NSUUID, NSImage> = { let c = NSCache<NSUUID, NSImage>(); c.countLimit = 400; return c }()

    func cached(_ item: ShelfItem) -> NSImage? { store.object(forKey: item.id as NSUUID) }

    func load(_ item: ShelfItem, size: CGFloat, completion: @escaping (NSImage) -> Void) {
        if let img = store.object(forKey: item.id as NSUUID) { completion(img); return }
        guard item.kind == .file, let url = item.url else { completion(item.fallbackIcon); return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                               scale: scale, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            DispatchQueue.main.async {
                let img = rep?.nsImage ?? item.fallbackIcon
                self?.store.setObject(img, forKey: item.id as NSUUID)
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

/// File size / folder flag, cached per path. The shelf header and every list row used to stat
/// each file on every SwiftUI render (sync disk I/O on the main thread during drags).
enum FileMeta {
    private static var cache: [String: (dir: Bool, size: Int64)] = [:]
    static func of(_ url: URL) -> (dir: Bool, size: Int64) {
        if let m = cache[url.path] { return m }
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        let m = (v?.isDirectory == true, Int64(v?.fileSize ?? 0))
        if cache.count > 2000 { cache.removeAll() }
        cache[url.path] = m
        return m
    }
}
