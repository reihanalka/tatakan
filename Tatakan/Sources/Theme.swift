import AppKit
import SwiftUI

/// Tatakan design tokens — same family as Puteran (Nothing-style), adapted for a translucent "smoke" shelf.
/// Light default, dark follows the system. Accent #F07A42 only for active states.
enum PT {
    static func dyn(_ light: UInt32, _ dark: UInt32, _ la: CGFloat = 1, _ da: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark, alpha: da) : NSColor(hex: light, alpha: la)
        })
    }

    static let panel = dyn(0xF4F4F2, 0x161616)
    static let card = dyn(0xECECEA, 0x1F1F1F)
    static let ink = dyn(0x111111, 0xF2F2F0)
    static let onInk = dyn(0xFFFFFF, 0x111111)
    static let mute = dyn(0x6E6E6C, 0x8A8A88)
    static let line = dyn(0xD9D9D6, 0x2C2C2C)
    /// System accent (was #F07A42). From NSColor, not `Color.accentColor`: the latter turns grey
    /// whenever the window isn't key, and these panels are non-activating.
    static let accent = Color(nsColor: .controlAccentColor)
    static let accentSoft = dyn(0xF9D9C8, 0x4A2A1C)

    // Smoke: tokens laid over a blur, so the desktop shows through.
    static let smoke = dyn(0xF4F4F2, 0x161616, 0.62, 0.58)
    static let smokeCard = dyn(0xFFFFFF, 0x2A2A2A, 0.55, 0.55)
    static let smokeLine = dyn(0x000000, 0xFFFFFF, 0.10, 0.10)
    static let dot = dyn(0x000000, 0xFFFFFF, 0.16, 0.14)

    private static let wght = 0x7767_6874 // 'wght'

    private static func variable(_ family: String, _ size: CGFloat, _ weight: CGFloat) -> Font {
        let attrs: [NSFontDescriptor.AttributeName: Any] = [
            .family: family,
            NSFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String): [wght: weight],
        ]
        if let f = NSFont(descriptor: NSFontDescriptor(fontAttributes: attrs), size: size) { return Font(f) }
        return .system(size: size, weight: .bold, design: .monospaced)
    }

    // Typography is SF now (macOS 27 native). Same API as the original Doto / Space Grotesk / Space Mono
    // helpers, so every call site follows without being rewritten.
    private static func w(_ v: CGFloat) -> Font.Weight {
        switch v { case ..<350: .regular; case ..<550: .medium; case ..<650: .semibold; case ..<750: .bold; default: .heavy }
    }
    /// Numerals and big display words: SF Pro Rounded, tabular digits.
    static func dot(_ size: CGFloat) -> Font { .system(size: size, weight: .semibold, design: .rounded).monospacedDigit() }
    /// UI text.
    static func ui(_ size: CGFloat, _ weight: CGFloat = 500) -> Font { .system(size: size, weight: w(weight)) }
    /// Small labels (were uppercase Space Mono).
    static func mono(_ size: CGFloat, bold: Bool = false) -> Font {
        .system(size: size + 1.5, weight: bold ? .semibold : .medium).monospacedDigit()
    }
    static func nsMono(_ size: CGFloat) -> NSFont {
        NSFont(name: "SpaceMono-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    static func registerFonts() {
        guard let dir = Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for f in files where f.pathExtension.lowercased() == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    static func n2(_ n: Int) -> String { String(format: "%02d", min(n, 99)) }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Small uppercase mono label (Puteran's Label9).
struct Label9: View {
    let text: String
    var color: Color = PT.mute
    init(_ t: String, color: Color = PT.mute) { text = t; self.color = color }
    var body: some View {
        Text(text).font(PT.mono(9)).foregroundStyle(color).lineLimit(1)
    }
}

/// Puteran-style dot-matrix field. Dots light up in the accent when `active`.
struct DotGrid: View {
    var active: Bool
    var spacing: CGFloat = 9
    var body: some View {
        Canvas { ctx, size in
            let cols = Int(size.width / spacing), rows = Int(size.height / spacing)
            let ox = (size.width - CGFloat(cols - 1) * spacing) / 2
            let oy = (size.height - CGFloat(rows - 1) * spacing) / 2
            for r in 0..<rows {
                for c in 0..<cols {
                    let p = CGPoint(x: ox + CGFloat(c) * spacing, y: oy + CGFloat(r) * spacing)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.1, y: p.y - 1.1, width: 2.2, height: 2.2)),
                             with: .color(active ? PT.accent.opacity(0.75) : PT.dot))
                }
            }
        }
    }
}
