//
//  PhosphorFX.swift
//  Quake2TacticalWatchComputer
//
//  The same animated CRT "motion-tracker" overlay used on the watch — static
//  scanlines, a slow bright refresh sweep, a gentle flicker, and interference
//  lines that jump around — so the iPhone HUD has the Alien-films look too.
//

import SwiftUI

extension View {
    /// Dodgy-CRT warp: random intervals + on tap + whenever `trigger` changes
    /// (e.g. taking a hit). Event-driven — idle between glitches. `severity`
    /// (0…1, from low health) makes it fire faster and warp harder.
    func crtGlitch(trigger: Int = 0, severity: Double = 0) -> some View {
        modifier(CRTGlitch(trigger: trigger, severity: severity))
    }
}

struct CRTGlitch: ViewModifier {
    let trigger: Int
    var severity: Double = 0
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
            .task(id: Int(severity * 4)) {
                while !Task.isCancelled {
                    let lo = 4.0 - 3.5 * severity, hi = 8.0 - 6.5 * severity
                    try? await Task.sleep(for: .seconds(Double.random(in: lo...hi)))
                    if Task.isCancelled { return }
                    fire()
                }
            }
    }

    /// Single owner: cancel any in-flight glitch and start a fresh one.
    private func fire() {
        glitchTask?.cancel()
        glitchTask = Task { @MainActor in await glitch() }
    }

    @MainActor private func glitch() async {
        defer { withAnimation(.easeOut(duration: 0.12)) { dx = 0; sx = 1; sy = 1 } }
        let amp = CGFloat(7 + 16 * severity)
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

/// A quick "CRT re-sync" wobble — scale / tilt / blur that springs back — played
/// whenever `trigger` changes (we bump it on every portrait↔landscape flip) so
/// reorienting the phone feels like the tactical computer physically re-aligning
/// its deflection coils, not a flat layout swap.
struct ScreenWobble: ViewModifier {
    var trigger: Int

    struct Values {
        var scale: Double = 1.0
        var rotation: Double = 0.0
        var blur: Double = 0.0
        var bright: Double = 0.0
    }

    func body(content: Content) -> some View {
        content.keyframeAnimator(initialValue: Values(), trigger: trigger) { view, v in
            view
                .scaleEffect(v.scale)
                .rotationEffect(.degrees(v.rotation))
                .blur(radius: v.blur)
                .brightness(v.bright)
        } keyframes: { _ in
            // Overshoot then a loose, bouncy settle — the "wobble".
            KeyframeTrack(\.scale) {
                SpringKeyframe(1.07, duration: 0.13, spring: .snappy)
                CubicKeyframe(0.965, duration: 0.13)
                SpringKeyframe(1.0, duration: 0.60, spring: .bouncy)
            }
            KeyframeTrack(\.rotation) {
                CubicKeyframe(-1.8, duration: 0.10)
                CubicKeyframe(1.2, duration: 0.12)
                CubicKeyframe(-0.6, duration: 0.12)
                SpringKeyframe(0.0, duration: 0.55, spring: .bouncy)
            }
            // Brief defocus + a phosphor flare as the picture rebuilds.
            KeyframeTrack(\.blur) {
                CubicKeyframe(4.0, duration: 0.10)
                CubicKeyframe(0.0, duration: 0.45)
            }
            KeyframeTrack(\.bright) {
                CubicKeyframe(0.22, duration: 0.08)
                CubicKeyframe(0.0, duration: 0.45)
            }
        }
    }
}

extension View {
    /// Play the CRT re-sync wobble each time `trigger` changes.
    func screenWobble(_ trigger: Int) -> some View { modifier(ScreenWobble(trigger: trigger)) }
}

/// Make a view flicker like a failing tube, scaled by `severity` (0 = steady).
/// Idle (no animation) when healthy.
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

/// Full-screen "cracked glass" that shatters across the display on death, then
/// fades. Drawn procedurally (radial cracks + branches from a random impact).
struct CrackOverlay: View {
    /// Picks the crack pattern — pass deathCount so each death shatters uniquely.
    var seed: Int
    /// While true the shattered glass stays on screen; it fades out when a new
    /// game starts (the marine is dead until then).
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
            shown = max(1, seed)                                   // snap the glass
            withAnimation(.easeOut(duration: 0.06)) { opacity = 1 }
        } else {
            withAnimation(.easeIn(duration: 0.6)) { opacity = 0 }  // new game: clear
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
        let n = 8 + Int(rng.unit() * 5)

        for i in 0..<n {
            var a = (Double(i) / Double(n)) * 2 * .pi + (rng.unit() - 0.5)
            var p = impact
            let segs = 6 + Int(rng.unit() * 5)
            let step = reach * (0.6 + 0.5 * rng.unit()) / Double(segs)
            var path = Path(); path.move(to: impact)
            for _ in 0..<segs {
                a += (rng.unit() - 0.5) * 0.6
                p = CGPoint(x: p.x + cos(a) * step, y: p.y + sin(a) * step)
                path.addLine(to: p)
                if rng.unit() < 0.45 {
                    var bp = p, ba = a + (rng.unit() - 0.5) * 1.3
                    var br = Path(); br.move(to: p)
                    for _ in 0..<3 {
                        ba += (rng.unit() - 0.5) * 0.7
                        bp = CGPoint(x: bp.x + cos(ba) * step * 0.55, y: bp.y + sin(ba) * step * 0.55)
                        br.addLine(to: bp)
                    }
                    ctx.stroke(br, with: .color(dark), lineWidth: 2.0)
                    ctx.stroke(br, with: .color(glass), lineWidth: 0.8)
                }
            }
            ctx.stroke(path, with: .color(dark), lineWidth: 3.0)
            ctx.stroke(path, with: .color(glass), lineWidth: 1.3)
        }

        for k in 0..<3 {
            let rr = (16.0 + Double(k) * 26.0) * (0.8 + rng.unit() * 0.7)
            let rect = CGRect(x: impact.x - rr, y: impact.y - rr, width: rr * 2, height: rr * 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(glass.opacity(0.5)), lineWidth: 1.0)
        }
    }
}

/// Persistent low-health alarm — a skull-and-crossbones that pulses amber→red and
/// slow→fast as `severity` (0 ≈ 35% HP … 1 = 0% HP) rises. Distinct from the
/// 3×-on-death DeathFlash: this stays up the whole time the marine is wounded,
/// centred over the HUD at low opacity between pulses so the readouts stay legible.
struct LowHealthSkull: View {
    var severity: Double
    var size: CGFloat = 168

    var body: some View {
        if severity <= 0 {
            EmptyView()
        } else {
            let s = min(max(severity, 0), 1)
            let color = Phosphor.alarm(s)
            // Slow (~1.05 s) when just wounded → fast (~0.27 s) near death; below
            // 15% HP (s ≈ 0.57) it's already pulsing hard and quick.
            let period = 1.05 - 0.78 * s
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: period) / period
                let pulse = 0.5 - 0.5 * cos(phase * 2 * .pi)   // 0→1→0
                Image("skull")
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(color)
                    .shadow(color: color.opacity(0.85), radius: 14)
                    .opacity((0.22 + 0.6 * s) * pulse + 0.06)
                    .scaleEffect(1.0 + 0.14 * s * pulse)
            }
            .allowsHitTesting(false)
        }
    }
}

/// Permanent death marker — a red skull that stays lit (slow, ominous breathing
/// pulse) from the moment the marine dies until a new game starts. Pairs with the
/// held CrackOverlay so a glance says "you're dead".
struct DeadSkull: View {
    var dead: Bool
    var size: CGFloat = 200
    var body: some View {
        if dead {
            TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let pulse = 0.5 - 0.5 * cos(t * 2 * .pi / 1.5)   // slow breathing
                Image("skull")
                    .renderingMode(.template).resizable().scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(Phosphor.danger)
                    .shadow(color: Phosphor.danger.opacity(0.9), radius: 20)
                    .opacity(0.62 + 0.32 * pulse)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// A ♥ that pulses in time with the player's real heart rate, BPM beside it —
/// the iPhone twin of the watch HUD's HeartBeat. Sharp spike per beat.
struct HeartBeat: View {
    let bpm: Int
    var glyphSize: CGFloat = 46
    var body: some View {
        let period = bpm > 0 ? 60.0 / Double(bpm) : 1.0
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let phase = t.truncatingRemainder(dividingBy: period) / period
            let beat = pow(max(0.0, sin(phase * .pi * 2)), 8)   // sharp spike
            HStack(spacing: 4) {
                Text("♥")
                    .font(.system(size: glyphSize, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Phosphor.danger)
                    .phosphorGlow(Phosphor.danger, radius: 7)
                    .scaleEffect(1.0 + 0.35 * beat)
                Text("\(bpm)")
                    .font(.system(size: glyphSize * 0.55, weight: .bold, design: .monospaced))
                    .foregroundStyle(Phosphor.amberDim)
                    .contentTransition(.numericText())
            }
            .lineLimit(1).minimumScaleFactor(0.5)
        }
    }
}

struct ScanlineOverlay: View {
    /// Retained for source compatibility; the static grid is always drawn and the
    /// glow always animates while on-screen (TimelineView pauses in background).
    var active: Bool = true

    private static let glow = Color(red: 1.0, green: 0.72, blue: 0.15)   // amber phosphor

    var body: some View {
        ZStack {
            // Static scanline grid — drawn once, kept off the per-frame path.
            Canvas { ctx, size in Self.drawScanlines(&ctx, size) }
                .allowsHitTesting(false)
            // Animated phosphor glow.
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                Canvas { ctx, size in
                    Self.drawDynamic(&ctx, size, t: timeline.date.timeIntervalSinceReferenceDate)
                }
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }

    /// Static scanline grid (drawn once).
    private static func drawScanlines(_ ctx: inout GraphicsContext, _ size: CGSize) {
        ctx.blendMode = .multiply
        let spacing: CGFloat = 3
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                     with: .color(.black.opacity(0.18)))
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
        let bandH = size.height * 0.18
        let bandY = CGFloat(phase) * (size.height + bandH) - bandH
        let band = Gradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: glow.opacity(0.10), location: 0.5),
            .init(color: .clear, location: 1.0),
        ])
        ctx.fill(Path(CGRect(x: 0, y: bandY, width: size.width, height: bandH)),
                 with: .linearGradient(band,
                                       startPoint: CGPoint(x: 0, y: bandY),
                                       endPoint: CGPoint(x: 0, y: bandY + bandH)))

        // 3) Gentle global flicker.
        let flicker = 0.5 + 0.5 * sin(t * 11.0)
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(glow.opacity(0.012 + 0.016 * flicker)))

        // 4) Interference: a bright line that jumps a couple of times a second.
        let step = (t * 2.5).rounded(.down)
        let frac = sin(step * 91.17) * 0.5 + 0.5
        let ny = CGFloat(frac) * size.height
        ctx.fill(Path(CGRect(x: 0, y: ny, width: size.width, height: 1.5)),
                 with: .color(glow.opacity(0.14)))
    }
}

// MARK: - Terminal chrome (Aliens × Quake II — pure screen, no metal)

/// L-bracket "targeting frame" — the signature HUD box. No fill, no chrome; just
/// four corner brackets, like the Sulaco computer readouts and the Quake II
/// help-computer panels.
struct CornerBrackets: Shape {
    var length: CGFloat = 12
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

/// A bracket-framed readout panel with the title burned into the top rule — the
/// Quake II help-computer / Sulaco terminal look. No rounded "card" chrome.
struct ReadoutBox<Content: View>: View {
    var title: String? = nil
    var tint: Color = Phosphor.amberDim
    var bracket: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(tint.opacity(0.04))
            .overlay(CornerBrackets(length: bracket).stroke(tint.opacity(0.85), lineWidth: 1.5))
            .overlay(alignment: .topLeading) {
                if let title {
                    Text(title)
                        .font(.system(.caption2, design: .monospaced).weight(.bold))
                        .tracking(2.5)
                        .foregroundStyle(tint)
                        .padding(.horizontal, 5)
                        .background(Phosphor.background)
                        .offset(x: 14, y: -7)
                }
            }
    }
}

/// Diagonal caution striping — drawn behind critical / powerup banners.
struct HazardStripes: View {
    var color: Color = Phosphor.hazard
    var opacity: Double = 0.16
    var body: some View {
        Canvas { ctx, size in
            let w: CGFloat = 16
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

/// Blinking terminal cursor block — the "live prompt" tell.
struct CursorBlock: View {
    var color: Color = Phosphor.green
    var height: CGFloat = 14
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.53)) { tl in
            let on = Int(tl.date.timeIntervalSinceReferenceDate / 0.53) % 2 == 0
            Rectangle().fill(color)
                .frame(width: height * 0.55, height: height)
                .opacity(on ? 1 : 0.08)
                .phosphorGlow(color, radius: 4)
        }
    }
}

/// Top status rail: callsign · sector · uplink. Pure type + a glowing link dot.
struct TerminalHeader: View {
    var sector: String
    var live: Bool
    var body: some View {
        HStack(spacing: 8) {
            Text("USCM·TAC")
                .font(.system(.caption2, design: .monospaced).weight(.heavy))
                .tracking(2).foregroundStyle(Phosphor.amberDim)
            Rectangle().fill(Phosphor.amberDim.opacity(0.4)).frame(width: 1, height: 11)
            Text(sector.uppercased())
                .font(.system(.caption, design: .monospaced).weight(.bold))
                .tracking(1).foregroundStyle(Phosphor.green)
                .phosphorGlow(Phosphor.green, radius: 4)
                .lineLimit(1).minimumScaleFactor(0.6)
            Spacer(minLength: 6)
            Circle().fill(live ? Phosphor.green : Phosphor.danger)
                .frame(width: 7, height: 7)
                .phosphorGlow(live ? Phosphor.green : Phosphor.danger, radius: 6, intensity: 0.9)
            Text(live ? "ONLINE" : "OFFLINE")
                .font(.system(.caption2, design: .monospaced).weight(.bold))
                .tracking(1)
                .foregroundStyle(live ? Phosphor.green : Phosphor.danger)
                .phosphorGlow(live ? Phosphor.green : Phosphor.danger, radius: 4, intensity: 0.8)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Phosphor.amber.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Phosphor.amberDim.opacity(0.5)).frame(height: 1)
        }
    }
}

/// Near-black ground with a faint green CRT cast and an edge vignette — the
/// "lit glass in a dark room" feel, no solid flat fill.
struct TerminalBackground: View {
    var body: some View {
        ZStack {
            Phosphor.background
            RadialGradient(gradient: Gradient(colors: [Phosphor.crtCast.opacity(0.55), .clear]),
                           center: .center, startRadius: 2, endRadius: 420)
            RadialGradient(gradient: Gradient(colors: [.clear, Color.black.opacity(0.55)]),
                           center: .center, startRadius: 150, endRadius: 540)
        }
        .ignoresSafeArea()
    }
}

/// Thin segmented bar (HP / armor) with phosphor glow on the lit cells.
struct SegBar: View {
    var value: Int
    var maxValue: Int
    var color: Color
    var segments: Int = 20
    private var filled: Int {
        guard maxValue > 0 else { return 0 }
        let f = Double(min(max(value, 0), maxValue)) / Double(maxValue)
        return Int((f * Double(segments)).rounded())
    }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                Rectangle()
                    .fill(i < filled ? color : color.opacity(0.12))
                    .frame(maxWidth: .infinity)
                    .frame(height: 6)
            }
        }
        .phosphorGlow(color, radius: 3, intensity: 0.4)
    }
}
