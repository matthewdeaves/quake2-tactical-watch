//
//  Phosphor.swift
//  TacticalComputerWatchApp Watch App
//
//  Shared "marine terminal" palette — amber/green phosphor on near-black, with
//  the Aliens (1986) Sulaco/motion-tracker accents: hazard amber, a faint green
//  CRT cast, and a phosphor-bloom modifier. Pure screen — no chrome/metal.
//  Duplicated verbatim from the iOS target.
//

import SwiftUI

enum Phosphor {
    /// Primary amber phosphor.
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.15)
    /// Dimmed amber for labels / framing.
    static let amberDim = Color(red: 0.78, green: 0.52, blue: 0.10)
    /// Secondary green phosphor (sector, weapon, OK states, motion-tracker green).
    static let green = Color(red: 0.45, green: 1.0, blue: 0.45)
    /// Alert red (low HP, damage, active powerup).
    static let danger = Color(red: 1.0, green: 0.28, blue: 0.20)
    /// Cyan phosphor — ammo readout.
    static let cyan = Color(red: 0.36, green: 0.80, blue: 1.0)
    /// Pale phosphor white — selected weapon.
    static let pale = Color(red: 1.0, green: 0.93, blue: 0.78)
    /// Near-black terminal background.
    static let background = Color(red: 0.04, green: 0.04, blue: 0.03)

    // MARK: Aliens × Quake II accents

    /// Hazard amber for caution striping / wounded states.
    static let hazard = Color(red: 1.0, green: 0.62, blue: 0.0)
    /// Hairline framing colour.
    static let line = amberDim.opacity(0.5)
    /// A barely-there green CRT cast layered into screen backgrounds.
    static let crtCast = Color(red: 0.05, green: 0.11, blue: 0.06)

    /// HP → phosphor colour: amber when healthy, hazard amber wounded,
    /// danger red critical. Drives the headline vital readout.
    static func vital(_ hp: Int) -> Color {
        if hp <= 25 { return danger }
        if hp <= 50 { return hazard }
        return amber
    }

    /// Low-health alarm colour: amber at the warning threshold, ramping smoothly
    /// to danger red as `severity` (0…1) climbs — drives the pulsing skull.
    static func alarm(_ severity: Double) -> Color {
        let s = min(max(severity, 0), 1)
        return Color(red: 1.0, green: 0.62 - 0.34 * s, blue: 0.20 * s)
    }
}

extension View {
    /// Phosphor bloom — a soft glow in the readout's own colour, so numerals look
    /// like lit phosphor on glass rather than flat text. Just layered shadows, so
    /// it's static (no per-frame cost): the single biggest "on-glass" upgrade.
    func phosphorGlow(_ color: Color, radius: CGFloat = 5, intensity: Double = 0.55) -> some View {
        self
            .shadow(color: color.opacity(intensity), radius: radius * 0.4)
            .shadow(color: color.opacity(intensity * 0.55), radius: radius)
    }
}
