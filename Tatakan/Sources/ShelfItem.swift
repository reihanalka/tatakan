import AppKit
import UniformTypeIdentifiers

/// One thing sitting on a shelf: a file, a web link, or a text snippet.
struct ShelfItem: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case file, link, text }

    var id = UUID()
    var kind: Kind
    var url: URL?
    var text: String?
    var title: String

    static func file(_ url: URL) -> ShelfItem {
        ShelfItem(kind: .file, url: url, text: nil, title: url.lastPathComponent)
    }

    static func link(_ url: URL, title: String?) -> ShelfItem {
        let t = (title?.isEmpty == false ? title! : (url.host ?? url.absoluteString))
        return ShelfItem(kind: .link, url: url, text: nil, title: t)
    }

    static func text(_ s: String) -> ShelfItem {
        let firstLine = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
        return ShelfItem(kind: .text, url: nil, text: s, title: String(firstLine.prefix(60)))
    }

    /// Still points at something real? (files can be moved/deleted behind our back)
    var isAlive: Bool {
        guard kind == .file, let url else { return true }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func pasteboardWriter() -> NSPasteboardWriting {
        switch kind {
        case .file, .link: return (url ?? URL(fileURLWithPath: "/")) as NSURL
        case .text: return (text ?? "") as NSString
        }
    }

    var fallbackIcon: NSImage {
        switch kind {
        case .file:
            return NSWorkspace.shared.icon(forFile: url?.path ?? "/")
        case .link:
            return NSImage(systemSymbolName: "link", accessibilityDescription: nil) ?? NSImage()
        case .text:
            return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil) ?? NSImage()
        }
    }
}

/// Reads anything droppable/pasteable into shelf items.
enum Ingest {
    static let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tatakan", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .png, .tiff,
         NSPasteboard.PasteboardType("public.jpeg"),
         NSPasteboard.PasteboardType("public.url")]
        + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// Fresh unique folder so names never collide.
    static func newTempFolder() -> URL {
        let dir = cacheDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Synchronous part. File promises are returned separately (they arrive async).
    static func items(from pb: NSPasteboard) -> (items: [ShelfItem], promises: [NSFilePromiseReceiver]) {
        // 1. Real files / folders
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return (urls.map(ShelfItem.file), [])
        }
        // 2. Raw image data (e.g. images dragged from a browser)
        if let type = pb.availableType(from: [.png, NSPasteboard.PasteboardType("public.jpeg"), .tiff]),
           let data = pb.data(forType: type), let saved = saveImage(data, type: type, pb: pb) {
            return ([.file(saved)], [])
        }
        // 3. File promises (Mail attachments, Photos, some browsers)
        if let promises = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            return ([], promises)
        }
        // 4. Web links
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let name = pb.string(forType: NSPasteboard.PasteboardType("public.url-name"))
            return (urls.map { .link($0, title: urls.count == 1 ? name : nil) }, [])
        }
        // 5. Plain text (a URL typed as text becomes a link)
        if let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if let u = URL(string: trimmed), let scheme = u.scheme, ["http", "https"].contains(scheme), !trimmed.contains(" ") {
                return ([.link(u, title: nil)], [])
            }
            return ([.text(s)], [])
        }
        return ([], [])
    }

    private static func saveImage(_ data: Data, type: NSPasteboard.PasteboardType, pb: NSPasteboard) -> URL? {
        var name = "Image"
        if let u = (pb.readObjects(forClasses: [NSURL.self]) as? [URL])?.first {
            let base = u.deletingPathExtension().lastPathComponent
            if !base.isEmpty, base != "/" { name = String(base.prefix(80)) }
        }
        let dir = newTempFolder()
        if type == .tiff {
            guard let rep = NSBitmapImageRep(data: data),
                  let png = rep.representation(using: .png, properties: [:]) else { return nil }
            let out = dir.appendingPathComponent(name + ".png")
            return (try? png.write(to: out)) != nil ? out : nil
        }
        let ext = type == .png ? "png" : "jpg"
        let out = dir.appendingPathComponent(name + "." + ext)
        return (try? data.write(to: out)) != nil ? out : nil
    }
}
