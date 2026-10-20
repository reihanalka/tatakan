import AppKit
import Vision
import ImageIO
import UniformTypeIdentifiers

/// Everything you can do with items on a shelf.
enum Actions {

    // MARK: Clipboard
    static func copy(_ items: [ShelfItem], shelf: Shelf) {
        guard !items.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(items.map { $0.pasteboardWriter() })
        shelf.toast(items.count == 1 ? "Copied" : "Copied \(items.count) items")
    }

    static func paste(into shelf: Shelf) {
        let r = Ingest.items(from: .general)
        shelf.add(r.items)
        if r.items.isEmpty { shelf.toast("Clipboard is empty") }
    }

    static func copyPaths(_ items: [ShelfItem], shelf: Shelf) {
        let paths = items.compactMap { $0.kind == .file ? $0.url?.path : $0.url?.absoluteString ?? $0.text }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.joined(separator: "\n"), forType: .string)
        shelf.toast("Paths copied")
    }

    // MARK: Finder
    static func open(_ items: [ShelfItem]) {
        for i in items {
            switch i.kind {
            case .file, .link: if let u = i.url { NSWorkspace.shared.open(u) }
            case .text:
                let u = Ingest.newTempFolder().appendingPathComponent("Snippet.txt")
                try? (i.text ?? "").write(to: u, atomically: true, encoding: .utf8)
                NSWorkspace.shared.open(u)
            }
        }
    }

    static func reveal(_ items: [ShelfItem]) {
        let urls = items.compactMap { $0.kind == .file ? $0.url : nil }
        if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    /// Copy or move files into a folder the user picks.
    static func saveTo(_ items: [ShelfItem], shelf: Shelf, move: Bool) {
        let files = items.filter { $0.kind == .file }
        guard !files.isEmpty else { shelf.toast("No files to save"); return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move Here" : "Save Here"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dir = panel.url else { return }

        var done = 0
        var moved: [ShelfItem] = []
        for f in files {
            guard let src = f.url else { continue }
            let dst = uniqueURL(dir.appendingPathComponent(src.lastPathComponent))
            do {
                if move { try FileManager.default.moveItem(at: src, to: dst); moved.append(.file(dst)) }
                else { try FileManager.default.copyItem(at: src, to: dst) }
                done += 1
            } catch { NSLog("Tatakan save failed: \(error)") }
        }
        if move { shelf.replace(files, with: moved) }
        shelf.toast("\(move ? "Moved" : "Saved") \(done) to \(dir.lastPathComponent)")
    }

    // MARK: Share
    /// Full macOS share sheet (AirDrop, Messages, Mail, Notes, WhatsApp, …).
    static func share(_ items: [ShelfItem], from view: NSView, rect: NSRect) {
        let objects = shareable(items)
        guard !objects.isEmpty else { return }
        NSSharingServicePicker(items: objects).show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    /// One-click send through a specific service (AirDrop, Messages, Mail).
    static func send(_ items: [ShelfItem], via name: NSSharingService.Name, shelf: Shelf) {
        // AirDrop can't take raw text, so text snippets become .txt files for every service.
        let objects = shareable(items, textAsFile: true)
        guard !objects.isEmpty else { shelf.toast("Nothing to share"); return }
        guard let service = NSSharingService(named: name), service.canPerform(withItems: objects) else {
            shelf.toast(name == .sendViaAirDrop ? "AirDrop unavailable" : "Can't share this")
            return
        }
        ShareRelay.shared.attach(service, shelf: shelf)
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: objects)
    }

    static func shareable(_ items: [ShelfItem], textAsFile: Bool = false) -> [Any] {
        items.compactMap { i -> Any? in
            switch i.kind {
            case .file, .link: return i.url
            case .text:
                guard textAsFile else { return (i.text ?? "") as NSString }
                let name = i.title.replacingOccurrences(of: "/", with: "-").prefix(40)
                let u = Ingest.newTempFolder().appendingPathComponent((name.isEmpty ? "Snippet" : String(name)) + ".txt")
                return (try? (i.text ?? "").write(to: u, atomically: true, encoding: .utf8)) != nil ? u : nil
            }
        }
    }

    // MARK: ZIP
    static func zip(_ items: [ShelfItem], shelf: Shelf) {
        let files = items.filter { $0.kind == .file }.compactMap(\.url)
        guard !files.isEmpty else { shelf.toast("Nothing to zip"); return }
        shelf.status = "Zipping…"
        let name = files.count == 1 ? files[0].deletingPathExtension().lastPathComponent
                                    : (shelf.name.isEmpty ? "Archive" : shelf.name)
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Ingest.newTempFolder().appendingPathComponent(name + ".zip")
            let ok: Bool
            if files.count == 1 {
                ok = run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", files[0].path, out.path])
            } else {
                // Stage clones (APFS clonefile = instant, no extra space) so mixed folders zip flat.
                let stage = Ingest.newTempFolder().appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
                for f in files {
                    try? FileManager.default.copyItem(at: f, to: uniqueURL(stage.appendingPathComponent(f.lastPathComponent)))
                }
                ok = run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", stage.path, out.path])
                try? FileManager.default.removeItem(at: stage.deletingLastPathComponent())
            }
            DispatchQueue.main.async {
                if ok {
                    let zipped = items.filter { $0.kind == .file }
                    shelf.replace(zipped, with: [.file(out)])
                    shelf.toast("ZIP ready")
                } else { shelf.toast("ZIP failed") }
            }
        }
    }

    // MARK: Images
    enum ImageFormat { case png, jpg }

    static func isImage(_ i: ShelfItem) -> Bool {
        guard i.kind == .file, let u = i.url, let t = UTType(filenameExtension: u.pathExtension) else { return false }
        return t.conforms(to: .image)
    }

    /// maxSide: longest edge in px (nil = keep). scale: 0.5 etc (nil = keep).
    static func processImages(_ items: [ShelfItem], shelf: Shelf, maxSide: CGFloat? = nil,
                              scale: CGFloat? = nil, format: ImageFormat? = nil) {
        let images = items.filter(isImage)
        guard !images.isEmpty else { shelf.toast("No images selected"); return }
        shelf.status = "Processing…"
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [ShelfItem] = []
            var sources: [ShelfItem] = []
            for item in images {
                guard let url = item.url, let out = writeImage(url, maxSide: maxSide, scale: scale, format: format) else { continue }
                results.append(.file(out)); sources.append(item)
            }
            DispatchQueue.main.async {
                shelf.replace(sources, with: results)
                shelf.toast(results.isEmpty ? "Couldn't process" : "Done · \(results.count) image\(results.count == 1 ? "" : "s")")
            }
        }
    }

    private static func writeImage(_ url: URL, maxSide: CGFloat?, scale: CGFloat?, format: ImageFormat?) -> URL? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        var target = max(w, h)
        if let maxSide { target = min(target, maxSide) }
        if let scale { target = max(w, h) * scale }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(target.rounded()),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }

        let ext: String, type: UTType
        switch format {
        case .png: ext = "png"; type = .png
        case .jpg: ext = "jpg"; type = .jpeg
        case nil:
            let original = UTType(filenameExtension: url.pathExtension)
            if original == .png { ext = "png"; type = .png } else { ext = "jpg"; type = .jpeg }
        }
        var base = url.deletingPathExtension().lastPathComponent
        if maxSide != nil || scale != nil { base += "@\(cg.width)px" }
        let out = Ingest.newTempFolder().appendingPathComponent(base + "." + ext)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out : nil
    }

    // MARK: OCR
    static func extractText(_ items: [ShelfItem], shelf: Shelf) {
        let images = items.filter(isImage)
        guard !images.isEmpty else { shelf.toast("No images selected"); return }
        shelf.status = "Reading text…"
        DispatchQueue.global(qos: .userInitiated).async {
            var chunks: [String] = []
            for item in images {
                guard let url = item.url,
                      let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                let req = VNRecognizeTextRequest()
                req.recognitionLevel = .accurate
                req.usesLanguageCorrection = true
                req.automaticallyDetectsLanguage = true
                try? VNImageRequestHandler(cgImage: cg).perform([req])
                let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                if !lines.isEmpty { chunks.append(lines.joined(separator: "\n")) }
            }
            DispatchQueue.main.async {
                let text = chunks.joined(separator: "\n\n")
                guard !text.isEmpty else { shelf.toast("No text found"); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                shelf.add([.text(text)])
                shelf.toast("Text copied")
            }
        }
    }

    // MARK: Helpers
    static func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        var n = 2
        while true {
            let c = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: c.path) { return c }
            n += 1
        }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
}
