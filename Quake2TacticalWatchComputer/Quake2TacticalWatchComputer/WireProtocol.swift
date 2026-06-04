//
//  WireProtocol.swift
//  Quake2TacticalWatchComputer
//
//  The on-the-wire contract with the Quake II engine patch
//  (old-mac-quake2 · src/client/cl_watchlink.c, branch watch-tactical-computer).
//
//  ⚠️  KEEP IN LOCKSTEP with cl_watchlink.c. The engine is already shipped and is
//      the authoritative side. This struct set mirrors exactly what the engine
//      emits as newline-delimited JSON over UDP (default port 27999). The JSON
//      transport is endianness-proof, so this works identically whether the
//      engine was built on a big-endian PPC Mac or a little-endian Intel Lion box.
//
//  Authoritative format (verified against cl_watchlink.c):
//
//    {"t":"vitals","hp":87,"armor":50,"ammo":24,"sel":"Super Shotgun",
//     "frags":3,"flashes":1,"layouts":0,"spec":0,"pu":{"icon":"p_quad","sec":18}}
//    {"t":"meta","level":"Outer Base","items":["Shells","Bullets", ...]}
//    {"t":"event","kind":"centerprint","msg":"You got the Railgun"}
//    {"t":"event","kind":"damage","health":1,"armor":0,"ammo":0}
//
//  This same file is duplicated verbatim in the watch target. If you change the
//  format, change it here, in the watch copy, AND in cl_watchlink.c + PLAN.md §2.
//

import Foundation

// Plain data types — opt out of the project's default @MainActor isolation so
// they can be decoded on the networking queue and shipped across actors freely.

/// The live status-bar heartbeat (~`watch_rate` Hz, default 10).
nonisolated struct Vitals: Codable, Equatable, Sendable {
    var hp: Int
    var armor: Int
    var ammo: Int
    /// Name of the currently selected item/weapon (resolved from CS_ITEMS).
    var sel: String
    var frags: Int
    /// STAT_FLASHES bitfield: bit0 health hit, bit1 armor hit, bit2 ammo.
    var flashes: Int
    /// STAT_LAYOUTS: bit0 scoreboard, bit1 inventory visible.
    var layouts: Int
    /// STAT_SPECTATOR flag.
    var spec: Int
    var pu: Powerup

    nonisolated struct Powerup: Codable, Equatable, Sendable {
        /// CS_IMAGES name of the active powerup icon (e.g. "p_quad"), or "".
        var icon: String
        /// Seconds remaining on the powerup timer.
        var sec: Int

        var isActive: Bool { sec > 0 && !icon.isEmpty }

        /// A friendly label for the powerup, derived from the icon name.
        var label: String {
            let i = icon.lowercased()
            if i.contains("quad") { return "QUAD DAMAGE" }
            if i.contains("invul") || i.contains("pent") { return "INVULNERABLE" }
            if i.contains("envir") { return "ENVIRO-SUIT" }
            if i.contains("rebreather") || i.contains("breath") { return "REBREATHER" }
            if i.contains("silencer") { return "SILENCER" }
            // Quake-1 Ring of Shadows. Checked before "ir" below — "ring"
            // contains that substring — and kept game-neutral on purpose.
            if i.contains("ring") || i.contains("invis") { return "INVISIBILITY" }
            if i.contains("ir") || i.contains("goggles") { return "IR GOGGLES" }
            return icon.uppercased()
        }
    }

    /// True on the frame the marine was hit (any subsystem flashed).
    var isHit: Bool { flashes != 0 }
}

/// Sent once per map load: the level name and the item-name lookup table.
/// NB: `items` is the *full set of item names known on this map* (from the
/// CS_ITEMS configstrings), not a per-player owned-inventory snapshot — the
/// current engine feed does not transmit owned quantities (see PLAN.md §6).
nonisolated struct Meta: Codable, Equatable, Sendable {
    var level: String
    var items: [String]
}

/// The F1 "help computer" contents, forwarded as structured fields by the
/// engine (cl_watchlink.c parses HelpComputerMessage's fixed layout). Counts
/// are pre-formatted "found/total" strings.
nonisolated struct Objectives: Codable, Equatable, Sendable {
    var skill = ""
    var loc = ""
    var obj1 = ""
    var obj2 = ""
    var kills = ""
    var goals = ""
    var secrets = ""

    /// Nothing worth showing yet.
    var isEmpty: Bool {
        loc.isEmpty && obj1.isEmpty && obj2.isEmpty &&
        kills.isEmpty && goals.isEmpty && secrets.isEmpty
    }
}

/// A discrete, as-it-happens event.
nonisolated struct GameEvent: Codable, Equatable, Sendable, Identifiable {
    /// Event class: "damage", "centerprint", … (extensible).
    var kind: String

    // centerprint
    var msg: String?

    // damage — each is 1 when that subsystem was struck this frame.
    var health: Int?
    var armor: Int?
    var ammo: Int?

    // objectives — the F1 help-computer fields (kind == "objectives").
    var skill: String?
    var loc: String?
    var obj1: String?
    var obj2: String?
    var kills: String?
    var goals: String?
    var secrets: String?

    /// Stable identity for SwiftUI lists (assigned on receipt, not on the wire).
    var id = UUID()

    private enum CodingKeys: String, CodingKey {
        case kind, msg, health, armor, ammo
        case skill, loc, obj1, obj2, kills, goals, secrets
    }

    /// Which subsystems took damage this frame (for damage events).
    var damagedSystems: [String] {
        var out: [String] = []
        if (health ?? 0) != 0 { out.append("HEALTH") }
        if (armor ?? 0) != 0 { out.append("ARMOR") }
        if (ammo ?? 0) != 0 { out.append("AMMO") }
        return out
    }

    var isDamage: Bool { kind == "damage" }
    var isCenterprint: Bool { kind == "centerprint" }
    var isObjectives: Bool { kind == "objectives" }

    /// Build the structured F1 help-computer view from this event's fields.
    var asObjectives: Objectives? {
        guard isObjectives else { return nil }
        return Objectives(skill: skill ?? "", loc: loc ?? "",
                          obj1: obj1 ?? "", obj2: obj2 ?? "",
                          kills: kills ?? "", goals: goals ?? "", secrets: secrets ?? "")
    }
}

/// A decoded line from the feed. Decoding is tolerant: an unknown `t`, a
/// malformed line, or a partial datagram simply yields `nil` and is dropped.
nonisolated enum WireMessage: Equatable, Sendable {
    case vitals(Vitals)
    case meta(Meta)
    case event(GameEvent)

    private struct TypeProbe: Decodable { let t: String }

    /// Decode one complete JSON line (without the trailing newline).
    init?(jsonLine data: Data) {
        let decoder = JSONDecoder()
        guard let probe = try? decoder.decode(TypeProbe.self, from: data) else {
            return nil
        }
        switch probe.t {
        case "vitals":
            guard let v = try? decoder.decode(Vitals.self, from: data) else { return nil }
            self = .vitals(v)
        case "meta":
            guard let m = try? decoder.decode(Meta.self, from: data) else { return nil }
            self = .meta(m)
        case "event":
            guard let e = try? decoder.decode(GameEvent.self, from: data) else { return nil }
            self = .event(e)
        default:
            return nil
        }
    }
}
