//
//  PhosphorUI.swift
//  TacticalComputerWatchApp Watch App
//
//  Reusable "marine terminal" chrome: scanline overlay, panel framing, and a
//  blocky segmented bar gauge.
//

import SwiftUI

/// CRT terminal texture, animated like the blip counters / motion tracker in
/// the Alien films: static scanlines, a slow bright refresh sweep travelling
/// down the screen, a gentle flicker, and signal-interference lines that jump
/// around. Drawn over content; never intercepts touches. Animation pauses on
/// the Always-On display, so it's cheap when the wrist is down.
struct ScanlineOverlay: View {
    /// Pause the animation (static scanlines only) when there's no live feed, so
    /// the SIGNAL-LOST screen isn't burning frames.
    var active: Bool = true
    /// On the Always-On (dimmed) display we freeze the animation and draw only
    /// the cheap static scanlines, so the effect costs nothing when the wrist
    /// is down.
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        ZStack {
            // Static scanline grid — NEVER animates, so it's drawn once and kept
            // off the per-frame path (the big battery win vs redrawing it 24×/s).
            Canvas { ctx, size in Self.drawScanlines(&ctx, size) }
                .allowsHitTesting(false)
            // Animated phosphor (sweep + flicker + interference). Frozen on the
            // Always-On display — the real wrist-down battery case.
            if !dimmed && active {
                TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { timeline in
                    Canvas { ctx, size in
                        Self.drawDynamic(&ctx, size, t: timeline.date.timeIntervalSinceReferenceDate)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private static let glow = Color(red: 1.0, green: 0.72, blue: 0.15)   // amber phosphor

    /// Static scanline grid (drawn once).
    private static func drawScanlines(_ ctx: inout GraphicsContext, _ size: CGSize) {
        ctx.blendMode = .multiply
        let spacing: CGFloat = 3
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                     with: .color(.black.opacity(0.22)))
            y += spacing
        }
    }

    /// Animated phosphor glow (per frame).
    private static func drawDynamic(_ ctx: inout GraphicsContext, _ size: CGSize, t: Double) {
        // Everything here ADDS light (phosphor glow).
        ctx.blendMode = .plusLighter

        // 2) Slow bright sweep band travelling top→bottom (~6s loop).
        let period = 6.0
        let phase = t.truncatingRemainder(dividingBy: period) / period
        let bandH = size.height * 0.22
        let bandY = CGFloat(phase) * (size.height + bandH) - bandH
        let band = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: glow.opacity(0.12), location: 0.5),
            .init(color: .clear, location: 1.0),
        ])
        ctx.fill(Path(CGRect(x: 0, y: bandY, width: size.width, height: bandH)),
                 with: .linearGradient(band,
                                       startPoint: CGPoint(x: 0, y: bandY),
                                       endPoint: CGPoint(x: 0, y: bandY + bandH)))

        // 3) Gentle global flicker.
        let flicker = 0.5 + 0.5 * sin(t * 11.0)
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(glow.opacity(0.015 + 0.02 * flicker)))

        // 4) Interference: a bright line that jumps to a new row a couple of
        //    times a second (pseudo-random from a stepped time value).
        let step = (t * 2.5).rounded(.down)
        let frac = sin(step * 91.17) * 0.5 + 0.5
        let ny = CGFloat(frac) * size.height
        ctx.fill(Path(CGRect(x: 0, y: ny, width: size.width, height: 1.5)),
                 with: .color(glow.opacity(0.16)))
    }
}

extension View {
    /// Wrap a screen in the terminal look: black ground, scanlines, dark scheme.
    /// `animated` pauses the sweep when there's no live feed (battery).
    func phosphorScreen(animated: Bool = true) -> some View {
        self
            .background(Phosphor.background)
            .overlay(ScanlineOverlay(active: animated))
            .preferredColorScheme(.dark)
    }

    /// Dodgy-CRT warp: fires at random intervals, on a screen tap, and whenever
    /// `trigger` changes (e.g. taking a hit). Event-driven — idle (no redraws)
    /// between glitches, so the page indicator settles and battery is spared.
    /// `severity` (0…1, from low health) makes it fire faster and warp harder.
    func crtGlitch(trigger: Int = 0, severity: Double = 0) -> some View {
        modifier(CRTGlitch(trigger: trigger, severity: severity))
    }
}

struct CRTGlitch: ViewModifier {
    let trigger: Int
    var severity: Double = 0
    @Environment(\.isLuminanceReduced) private var dimmed
    @State private var dx: CGFloat = 0
    @State private var sx: CGFloat = 1
    @State private var sy: CGFloat = 1
    @State private var glitchTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .offset(x: dx)
            .scaleEffect(x: sx, y: sy)
            .simultaneousGesture(TapGesture().onEnded { fire() })
            .onChange(of: trigger) { _, _ in fire() }
            // Restart the idle loop when health severity crosses a band so the
            // cadence tightens as the marine bleeds out.
            .task(id: TaskKey(dimmed: dimmed, band: Int(severity * 4))) {
                guard !dimmed else { return }
                while !Task.isCancelled {
                    // 4–8s healthy → ~0.5–1.5s near death.
                    let lo = 4.0 - 3.5 * severity, hi = 8.0 - 6.5 * severity
                    try? await Task.sleep(for: .seconds(Double.random(in: lo...hi)))
                    if Task.isCancelled { return }
                    fire()
                }
            }
    }

    private struct TaskKey: Equatable { let dimmed: Bool; let band: Int }

    /// Single owner: cancel any in-flight glitch and start a fresh one, so
    /// overlapping taps/hits/auto-fires can never leave the screen stuck offset.
    private func fire() {
        glitchTask?.cancel()
        glitchTask = Task { @MainActor in await glitch() }
    }

    @MainActor private func glitch() async {
        defer { withAnimation(.easeOut(duration: 0.12)) { dx = 0; sx = 1; sy = 1 } }
        let amp = CGFloat(6 + 14 * severity)          // wider warp when wounded
        for _ in 0..<5 {
            if Task.isCancelled { return }
            withAnimation(.linear(duration: 0.04)) {
                dx = CGFloat.random(in: -amp...amp)
                sx = CGFloat.random(in: (0.99 - 0.03 * severity)...(1.01 + 0.02 * severity))
                sy = CGFloat.random(in: 1.0...(1.05 + 0.12 * severity))
            }
            try? await Task.sleep(for: .milliseconds(45))
        }
    }
}

/// Make a view flicker like a failing tube, scaled by `severity` (0 = steady).
/// Idle (no animation) when healthy, so it costs nothing until the marine is hurt.
struct CriticalFlicker: ViewModifier {
    var severity: Double
    func body(content: Content) -> some View {
        if severity <= 0 {
            content
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { tl in
                let step = (tl.date.timeIntervalSinceReferenceDate * 12).rounded(.down)
                let n = sin(step * 51.13) * 0.5 + 0.5
                content.opacity(n < 0.22 ? 1.0 - 0.55 * severity : 1.0)
            }
        }
    }
}

extension View {
    func criticalFlicker(_ severity: Double) -> some View { modifier(CriticalFlicker(severity: severity)) }
}

/// Persistent low-health alarm — a skull that pulses amber→red and slow→fast as
/// `severity` (0 ≈ 35% HP … 1 = 0% HP) rises. Distinct from the 3×-on-death
/// DeathFlash: it stays up the whole time the marine is wounded. Frozen (static,
/// no TimelineView) on Always-On to save battery.
struct LowHealthSkull: View {
    var severity: Double
    var size: CGFloat = 78
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        if severity <= 0 {
            EmptyView()
        } else {
            let s = min(max(severity, 0), 1)
            let color = Phosphor.alarm(s)
            Group {
                if dimmed {
                    skull(color, opacity: 0.45 + 0.3 * s, scale: 1)
                } else {
                    // Slow (~1.05 s) wounded → fast (~0.27 s) near death.
                    let period = 1.05 - 0.78 * s
                    TimelineView(.animation(minimumInterval: 1.0 / 24.0)) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let phase = t.truncatingRemainder(dividingBy: period) / period
                        let pulse = 0.5 - 0.5 * cos(phase * 2 * .pi)
                        skull(color, opacity: (0.22 + 0.6 * s) * pulse + 0.06,
                                     scale: 1.0 + 0.14 * s * pulse)
                    }
                }
            }
            .allowsHitTesting(false)
        }
    }

    private func skull(_ color: Color, opacity: Double, scale: Double) -> some View {
        Image("skull")
            .renderingMode(.template).resizable().scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
            .shadow(color: color.opacity(0.85), radius: 8)
            .opacity(opacity).scaleEffect(scale)
    }
}

/// Permanent death marker — a red skull that stays lit (slow ominous breathing
/// pulse) from death until a new game starts. Pairs with the held CrackOverlay.
struct DeadSkull: View {
    var dead: Bool
    var size: CGFloat = 96
    @Environment(\.isLuminanceReduced) private var dimmed
    var body: some View {
        if dead {
            Group {
                if dimmed {
                    skull(opacity: 0.7)
                } else {
                    TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                        let t = tl.date.timeIntervalSinceReferenceDate
                        let pulse = 0.5 - 0.5 * cos(t * 2 * .pi / 1.5)
                        skull(opacity: 0.62 + 0.32 * pulse)
                    }
                }
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
    private func skull(opacity: Double) -> some View {
        Image("skull")
            .renderingMode(.template).resizable().scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(Phosphor.danger)
            .shadow(color: Phosphor.danger.opacity(0.9), radius: 12)
            .opacity(opacity)
    }
}

/// Full-screen "cracked glass" that shatters across the display on death, then
/// fades. Drawn procedurally (radial cracks + branches from a random impact),
/// so there's no image asset to license and it scales to any screen.
struct CrackOverlay: View {
    /// Picks the crack pattern — pass deathCount so each death shatters uniquely.
    var seed: Int
    /// While true the shattered glass stays on screen; it fades when a new game
    /// starts (the marine is dead until then).
    var visible: Bool
    @State private var shown = 0
    @State private var opacity: Double = 0

    var body: some View {
        Canvas { ctx, size in
            guard shown > 0 else { return }
            Self.draw(&ctx, size, seed: UInt64(shown))
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .onChange(of: visible) { _, v in apply(v) }
        .onAppear { apply(visible) }
    }

    private func apply(_ v: Bool) {
        if v {
            shown = max(1, seed)
            withAnimation(.easeOut(duration: 0.06)) { opacity = 1 }
        } else {
            withAnimation(.easeIn(duration: 0.6)) { opacity = 0 }
        }
    }

    private struct RNG {
        var s: UInt64
        init(_ seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func unit() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(UInt64(1) << 53)
        }
    }

    static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, seed: UInt64) {
        var rng = RNG(seed &* 2654435761 &+ 1)
        let glass = Color.white.opacity(0.9)
        let dark = Color.black.opacity(0.5)
        let impact = CGPoint(x: size.width * (0.3 + 0.4 * rng.unit()),
                             y: size.height * (0.3 + 0.4 * rng.unit()))
        let reach = Double(max(size.width, size.height))
        let n = 7 + Int(rng.unit() * 4)

        for i in 0..<n {
            var a = (Double(i) / Double(n)) * 2 * .pi + (rng.unit() - 0.5)
            var p = impact
            let segs = 5 + Int(rng.unit() * 4)
            let step = reach * (0.55 + 0.5 * rng.unit()) / Double(segs)
            var path = Path(); path.move(to: impact)
            for _ in 0..<segs {
                a += (rng.unit() - 0.5) * 0.6
                p = CGPoint(x: p.x + cos(a) * step, y: p.y + sin(a) * step)
                path.addLine(to: p)
                if rng.unit() < 0.45 {       // branch
                    var bp = p, ba = a + (rng.unit() - 0.5) * 1.3
                    var br = Path(); br.move(to: p)
                    for _ in 0..<3 {
                        ba += (rng.unit() - 0.5) * 0.7
                        bp = CGPoint(x: bp.x + cos(ba) * step * 0.55, y: bp.y + sin(ba) * step * 0.55)
                        br.addLine(to: bp)
                    }
                    ctx.stroke(br, with: .color(dark), lineWidth: 1.4)
                    ctx.stroke(br, with: .color(glass), lineWidth: 0.6)
                }
            }
            ctx.stroke(path, with: .color(dark), lineWidth: 2.0)
            ctx.stroke(path, with: .color(glass), lineWidth: 1.0)
        }

        // Concentric stress rings — jittered, occasionally-broken polygons (not
        // perfect circles, which read as drawn-on rings rather than shattered glass).
        for k in 0..<2 {
            let baseR = (10.0 + Double(k) * 16.0) * (0.8 + rng.unit() * 0.7)
            let pts = 18 + Int(rng.unit() * 8)
            var ring = Path()
            var penDown = false
            for j in 0...pts {
                if rng.unit() < 0.10 { penDown = false; continue }   // gap
                let ang = (Double(j) / Double(pts)) * 2 * .pi + (rng.unit() - 0.5) * 0.10
                let rr = baseR * (1.0 + (rng.unit() - 0.5) * 0.30)   // ±15% wobble
                let pt = CGPoint(x: impact.x + cos(ang) * rr, y: impact.y + sin(ang) * rr)
                if penDown { ring.addLine(to: pt) } else { ring.move(to: pt); penDown = true }
            }
            ctx.stroke(ring, with: .color(dark), lineWidth: 1.2)
            ctx.stroke(ring, with: .color(glass.opacity(0.55)), lineWidth: 0.7)
        }
    }
}

/// A light blood splatter that appears when the marine takes damage and fades
/// out over a few seconds. Fully procedural (Canvas): a small cluster of
/// irregular dark-red blobs + scattered droplets biased to one screen edge, so
/// it frames the readouts instead of covering them. Re-splats on each hit
/// (`trigger` = hitCount). Deliberately restrained — "just enough", not a bath.
struct BloodSplat: View {
    var trigger: Int
    @State private var seed: UInt64 = 0
    @State private var opacity: Double = 0

    var body: some View {
        Canvas { ctx, size in
            guard seed != 0 else { return }
            Self.draw(&ctx, size, seed: seed)
        }
        .blur(radius: 0.9)
        .opacity(opacity)
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, t in
            guard t > 0 else { return }
            seed = UInt64(bitPattern: Int64(t)) &* 0x9E3779B97F4A7C15 &+ 0x1234567
            opacity = 0.5
            withAnimation(.easeOut(duration: 3.0)) { opacity = 0 }
        }
    }

    private struct RNG {
        var s: UInt64
        init(_ seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func unit() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(UInt64(1) << 53)
        }
    }

    static func draw(_ ctx: inout GraphicsContext, _ size: CGSize, seed: UInt64) {
        var rng = RNG(seed)
        let blood = Color(red: 0.45, green: 0.02, blue: 0.02)
        let dark  = Color(red: 0.24, green: 0.0,  blue: 0.0)
        let unit = Double(min(size.width, size.height))

        let left = rng.unit() < 0.5, top = rng.unit() < 0.5
        let origin = CGPoint(
            x: size.width  * (left ? 0.06 + 0.16 * rng.unit() : 0.78 + 0.16 * rng.unit()),
            y: size.height * (top  ? 0.06 + 0.18 * rng.unit() : 0.76 + 0.18 * rng.unit()))

        blob(&ctx, &rng, origin, unit * (0.09 + 0.05 * rng.unit()), blood)
        let drops = 6 + Int(rng.unit() * 6)
        for _ in 0..<drops {
            let ang = rng.unit() * 2 * .pi
            let dist = unit * (0.05 + 0.24 * rng.unit())
            let c = CGPoint(x: origin.x + cos(ang) * dist, y: origin.y + sin(ang) * dist)
            blob(&ctx, &rng, c, unit * (0.008 + 0.026 * rng.unit()), rng.unit() < 0.5 ? blood : dark)
        }
    }

    private static func blob(_ ctx: inout GraphicsContext, _ rng: inout RNG,
                             _ center: CGPoint, _ radius: Double, _ color: Color) {
        let pts = 10 + Int(rng.unit() * 6)
        var path = Path()
        for j in 0...pts {
            let ang = (Double(j) / Double(pts)) * 2 * .pi
            let rr = radius * (0.55 + 0.7 * rng.unit())
            let p = CGPoint(x: center.x + cos(ang) * rr, y: center.y + sin(ang) * rr)
            if j == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        ctx.fill(path, with: .color(color))
    }
}

/// A blocky segmented gauge (HP / armor / ammo).
struct SegmentGauge: View {
    let label: String
    let value: Int
    /// Value that maps to a full bar (e.g. 100 for HP/armor).
    let maxValue: Int
    var color: Color = Phosphor.amber
    var segments: Int = 12

    private var filled: Int {
        guard maxValue > 0 else { return 0 }
        let frac = Double(min(max(value, 0), maxValue)) / Double(maxValue)
        return Int((frac * Double(segments)).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Phosphor.amberDim)
                Spacer()
                Text("\(value)")
                    .font(.system(.callout, design: .monospaced).weight(.bold))
                    .foregroundStyle(color)
            }
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(i < filled ? color : color.opacity(0.15))
                        .frame(height: 6)
                }
            }
            .phosphorGlow(color, radius: 2, intensity: 0.4)
        }
    }
}

/// A bracket-framed readout panel — the title is burned into the top rule and
/// the four corners carry L-bracket "targeting" marks (Sulaco / Quake-II
/// help-computer look). No rounded card chrome.
struct TerminalPanel<Content: View>: View {
    let title: String
    var tint: Color = Phosphor.amberDim
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.top, 9).padding(.bottom, 7)
            .background(tint.opacity(0.05))
            .overlay(CornerBrackets(length: 8).stroke(tint.opacity(0.85), lineWidth: 1.2))
            .overlay(alignment: .topLeading) {
                Text(title)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(tint)
                    .padding(.horizontal, 4)
                    .background(Phosphor.background)
                    .offset(x: 9, y: -6)
            }
    }
}

// MARK: - Terminal chrome (Aliens × Quake II — pure screen, no metal)

/// L-bracket "targeting frame" — four corner brackets, no fill, no chrome.
struct CornerBrackets: Shape {
    var length: CGFloat = 10
    func path(in rect: CGRect) -> Path {
        let l = min(length, min(rect.width, rect.height) / 2.2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + l)); p.addLine(to: CGPoint(x: rect.minX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - l, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l)); p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + l, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY)); p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return p
    }
}

/// Diagonal caution striping — drawn behind a critical / powerup banner.
struct HazardStripes: View {
    var color: Color = Phosphor.hazard
    var opacity: Double = 0.18
    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = 12
            var x: CGFloat = -size.height
            while x < size.width {
                var p = Path()
                p.move(to: CGPoint(x: x, y: size.height))
                p.addLine(to: CGPoint(x: x + size.height, y: 0))
                p.addLine(to: CGPoint(x: x + size.height + w * 0.5, y: 0))
                p.addLine(to: CGPoint(x: x + w * 0.5, y: size.height))
                p.closeSubpath()
                ctx.fill(p, with: .color(color.opacity(opacity)))
                x += w
            }
        }
        .allowsHitTesting(false)
    }
}

/// Blinking terminal cursor block — the "live prompt" tell on the standby screen.
struct CursorBlock: View {
    var color: Color = Phosphor.green
    var height: CGFloat = 12
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { tl in
            let on = Int(tl.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Rectangle().fill(color)
                .frame(width: height * 0.55, height: height)
                .opacity(on ? 1 : 0.08)
        }
    }
}
