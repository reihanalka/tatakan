import AppKit
import SwiftUI

// Liquid Glass surfaces + Apple Intelligence (Siri) glow. Liquid Glass on macOS 26+, material fallback below.
// Surface language: native glass, washed with a black → transparent gradient from the top, so the
// Nook stays one piece with the hardware notch and dissolves into glass further down.

/// One motion vocabulary for the whole app (SwiftUI springs, the curves macOS 27 itself uses).
enum Motion {
    /// Opening: a touch of bounce, like the Dynamic Island growing.
    static let open = Animation.spring(duration: 0.5, bounce: 0.2)
    /// Closing: critically damped, no overshoot back into the notch.
    static let close = Animation.spring(duration: 0.36, bounce: 0)
    /// Size/state changes while visible (music starts, activity appears).
    static let settle = Animation.spring(duration: 0.45, bounce: 0.12)
    /// Tabs, selection.
    static let snappy = Animation.snappy(duration: 0.3)
    /// Hover, highlights.
    static let quick = Animation.smooth(duration: 0.18)
}

enum AI {
    /// Apple Intelligence glow palette (Siri edge light, approximated).
    static let palette: [Color] = [0xBC82F3, 0xF5B9EA, 0x8D9FFF, 0xFF6778, 0xFFBA71, 0xC686FF]
        .map { Color(nsColor: NSColor(hex: $0)) }
    static let loop: [Color] = palette + [palette[0]]
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Drives the glow for one surface. Animation only runs while `running` (open burst / drop hover);
/// at rest nothing ticks, so the app stays idle.
final class GlowDriver: ObservableObject {
    @Published var level: Double = 0        // rim intensity 0…1
    @Published var bloom: Double = 1        // 0 = burst start, 1 = finished (invisible)
    @Published var running = false
    @Published var revealed = true          // content blur-in on show
    /// Glass is a window-server effect: it does NOT follow SwiftUI size animations and showed up at
    /// full size on the first frame while the shape was still growing. So surfaces grow as solid
    /// smoke first and the glass materialises once the spring has (almost) landed.
    @Published var glassReady = true
    private var glassWork: DispatchWorkItem?

    func glassAfter(_ s: Double) {
        glassWork?.cancel()
        instantly { glassReady = false }
        let w = DispatchWorkItem { [weak self] in withAnimation(.easeOut(duration: 0.3)) { self?.glassReady = true } }
        glassWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }
    func glassOff() { glassWork?.cancel(); instantly { glassReady = false } }
    private var holding = false
    private var work: [DispatchWorkItem] = []

    private func after(_ s: Double, _ f: @escaping () -> Void) {
        let w = DispatchWorkItem(block: f); work.append(w)
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }
    private func cancel() { work.forEach { $0.cancel() }; work.removeAll() }
    private func instantly(_ f: () -> Void) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t, f)
    }

    /// "Siri wakes up": colour bloom from the top edge + rim flare that settles.
    func burst() {
        guard Settings.shared.aiGlow else { return }
        cancel()
        running = true
        if !AI.reduceMotion {
            instantly { bloom = 0 }
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 1.2)) { self.bloom = 1 } }
        }
        withAnimation(.easeOut(duration: 0.22)) { level = 1 }
        after(0.95) { [weak self] in self?.settle() }
    }

    /// Content reveal: blur + scale in (shelf windows).
    func reveal() {
        guard !AI.reduceMotion else { revealed = true; return }
        instantly { revealed = false }
        DispatchQueue.main.async { withAnimation(Motion.open) { self.revealed = true } }
    }

    /// Keep the glow lit while something is dragged over the surface.
    func hold(_ on: Bool) {
        holding = on
        if on {
            guard Settings.shared.aiGlow else { return }
            cancel(); running = true
            withAnimation(.easeOut(duration: 0.18)) { level = 1 }
        } else {
            settle()
        }
    }

    private func settle() {
        guard !holding else { return }
        withAnimation(.easeInOut(duration: 0.9)) { level = 0 }
        after(1.0) { [weak self] in
            guard let self, !self.holding, self.level == 0 else { return }
            self.running = false
        }
    }

    func reset() {
        cancel(); holding = false
        instantly { level = 0; bloom = 1 }
        running = false
    }
}

/// Native Liquid Glass with a black → transparent wash.
/// `solid` = fraction from the top that stays pure black (the hardware-notch band).
/// `glass == false` → plain black (closed notch: must be indistinguishable from the hardware).
struct LiquidSurface<S: Shape>: View {
    let shape: S
    var glass: Bool
    var solid: CGFloat = 0
    var topAlpha: Double = 1
    /// Solid smoke over the whole shape (1 = closed notch black, ~0.75 while growing, 0 = pure glass).
    var veil: Double? = nil

    var body: some View {
        ZStack {
            // Always present, switched to .identity when closed: removing it with a transition left the
            // glass frozen at full size while the shape shrank (the "shadow" ghost on close).
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(glass ? .regular.tint(Color.black.opacity(0.22)) : .identity, in: shape)
            } else {
                // Pre-Liquid Glass macOS: dark material in the same shape, same black wash on top.
                shape.fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                    .opacity(glass ? 1 : 0)
            }
            let s = min(max(solid, 0), 0.9)          // stops must stay ordered (closed: solid == 1)
            shape.fill(LinearGradient(stops: [
                .init(color: .black.opacity(topAlpha), location: 0),
                .init(color: .black.opacity(topAlpha), location: s),
                .init(color: .black.opacity(topAlpha * 0.62), location: s + (1 - s) * 0.4),
                .init(color: .black.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            shape.fill(Color.black).opacity(veil ?? (glass ? 0 : 1))
        }
    }
}

/// Siri edge light: an angular gradient that keeps turning, stacked from crisp to very soft,
/// masked inside the shape so it reads as light coming off the glass edge.
struct AIGlowRim<S: Shape>: View {
    let shape: S
    @ObservedObject var driver: GlowDriver

    var body: some View {
        // Always mounted (only the timeline pauses): a view inserted mid-animation takes the FINAL
        // geometry on its first frame, so the rim used to flash at full panel size while opening.
        ZStack {
                TimelineView(.animation(minimumInterval: 1.0 / 60, paused: AI.reduceMotion || !driver.running)) { ctx in
                    let t = AI.reduceMotion ? 0 : ctx.date.timeIntervalSinceReferenceDate
                    let a = AngularGradient(colors: AI.loop, center: .center,
                                            angle: .degrees((t * 110).truncatingRemainder(dividingBy: 360)))
                    let b = AngularGradient(colors: AI.loop.reversed(), center: .center,
                                            angle: .degrees((-t * 70 + 40).truncatingRemainder(dividingBy: 360)))
                    ZStack {
                        shape.stroke(a, lineWidth: 2)
                        shape.stroke(a, lineWidth: 7).blur(radius: 5)
                        shape.stroke(b, lineWidth: 20).blur(radius: 16).opacity(0.65)
                    }
                    .mask(shape)
                    .drawingGroup()                      // one offscreen Metal pass per frame
                }
        }
        .opacity(driver.level)
        .allowsHitTesting(false)
    }
}

/// One-shot colour bloom that swells from the top edge and dissolves (the Siri "wake").
struct AIBloom: View {
    @ObservedObject var driver: GlowDriver
    var body: some View {
        GeometryReader { g in
            let b = driver.bloom
            Ellipse()
                .fill(AngularGradient(colors: AI.loop, center: .center, angle: .degrees(-30)))
                .frame(width: g.size.width * 0.85, height: g.size.height * 1.3)
                .scaleEffect(0.12 + 1.3 * b, anchor: .center)
                .blur(radius: 30)
                .opacity(b >= 1 ? 0 : (1 - b) * 0.9)
                .position(x: g.size.width / 2, y: 0)
        }
        .allowsHitTesting(false)
    }
}

struct ScaleFrom: ViewModifier { var s: CGFloat
    func body(content: Content) -> some View { content.scaleEffect(s, anchor: .top) } }
struct Fade: ViewModifier { var o: Double
    func body(content: Content) -> some View { content.opacity(o) } }
struct Blur: ViewModifier { var r: CGFloat
    func body(content: Content) -> some View { content.blur(radius: r) } }

/// Apple Intelligence style content reveal: blur + fade + slight scale from the top.
struct BlurReveal: ViewModifier {
    var radius: CGFloat
    var opacity: Double
    var scale: CGFloat
    func body(content: Content) -> some View {
        content.blur(radius: radius).opacity(opacity).scaleEffect(scale, anchor: .top)
    }
}

extension AnyTransition {
    /// Panel content appearing: grows out of the notch with the same spring as the glass (scale
    /// anchored at the top centre), starts fully blurred and only comes into focus as it lands.
    /// Three tracks on their own clocks: scale = open spring, opacity = quick, blur = slower ease-out.
    static var aiReveal: AnyTransition {
        .asymmetric(insertion:
                        AnyTransition.modifier(active: ScaleFrom(s: 0.42), identity: ScaleFrom(s: 1)).animation(Motion.open)
                        .combined(with: .modifier(active: Fade(o: 0), identity: Fade(o: 1)).animation(.easeOut(duration: 0.16)))
                        .combined(with: .modifier(active: Blur(r: 22), identity: Blur(r: 0)).animation(.easeOut(duration: 0.5).delay(0.04))),
                    // leave fast and in place, so nothing lingers outside the shrinking shape
                    removal: .opacity.animation(.easeOut(duration: 0.1)))
    }
    /// Swapping tab bodies / track titles: blur cross-fade, no movement.
    static var tabSwap: AnyTransition {
        .modifier(active: BlurReveal(radius: 6, opacity: 0, scale: 1), identity: BlurReveal(radius: 0, opacity: 1, scale: 1))
    }
    /// Things growing out of the closed island (artwork, bars, activity).
    static var island: AnyTransition {
        .modifier(active: BlurReveal(radius: 4, opacity: 0, scale: 0.5), identity: BlurReveal(radius: 0, opacity: 1, scale: 1))
    }
}

// MARK: Back-deployment (macOS 14–25): Liquid Glass where available, closest material otherwise.
extension View {
    /// Sliding tab lens: interactive Liquid Glass capsule, or a light material capsule before macOS 26.
    @ViewBuilder func interactiveGlassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Capsule())
        } else {
            background(Capsule().fill(.thinMaterial).environment(\.colorScheme, .dark))
        }
    }

    /// Primary action button: `.glassProminent` on macOS 26+, `.borderedProminent` before.
    @ViewBuilder func prominentGlassButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }
}
