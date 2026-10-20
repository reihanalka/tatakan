// Asset tool: lists font names + rasterizes SVGs to PNG.
// usage: assettool fonts <dir>
//        assettool render <in.svg> <out.png> <px> [template|appicon]
import AppKit
import CoreText

let args = CommandLine.arguments
func fail(_ s: String) -> Never { FileHandle.standardError.write((s + "\n").data(using: .utf8)!); exit(1) }

if args.count >= 3 && args[1] == "fonts" {
    let dir = URL(fileURLWithPath: args[2])
    for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "ttf" {
        guard let descs = CTFontManagerCreateFontDescriptorsFromURL(f as CFURL) as? [CTFontDescriptor] else { continue }
        for d in descs {
            let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String ?? "?"
            let fam = CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String ?? "?"
            print("\(f.lastPathComponent): family=\(fam) ps=\(ps)")
        }
    }
    exit(0)
}

guard args.count >= 5, args[1] == "render" else { fail("bad args") }
var svg = (try? String(contentsOfFile: args[2], encoding: .utf8)) ?? ""
let px = Int(args[4]) ?? 64
let mode = args.count > 5 ? args[5] : ""
if mode == "template" || mode == "color" {
    // drop full-bleed background rect
    svg = svg.replacingOccurrences(of: #"<rect[^>]*/>"#, with: "", options: .regularExpression)
}
if mode == "template" {
    // force paths to black so macOS can tint it
    svg = svg.replacingOccurrences(of: #"fill:\s*#[0-9a-fA-F]{3,6}"#, with: "fill: #000000", options: .regularExpression)
}
guard let data = svg.data(using: .utf8), let img = NSImage(data: data) else { fail("NSImage could not load SVG") }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let full = NSRect(x: 0, y: 0, width: px, height: px)
NSColor.clear.set(); full.fill()
if mode == "appicon" {
    // macOS icon grid: 824/1024 body, continuous-ish corner radius
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    path.addClip()
    img.draw(in: body)
} else {
    img.draw(in: full)
}
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[3]))
print("wrote \(args[3])")
