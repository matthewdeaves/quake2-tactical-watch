//
//  GameState.swift
//  Quake2TacticalWatchComputer
//
//  The phone's authoritative view of the marine, fed by the UDP listener and
//  mirrored to the watch by WatchRelay. Also drives the on-phone debug HUD.
//

import Foundation
import Combine

@MainActor
final class GameState: ObservableObject {
    /// Latest status-bar heartbeat, or nil before the first packet.
    @Published private(set) var vitals: Vitals?
    /// Current map metadata (level name + item table).
    @Published private(set) var meta: Meta?
    /// F1 help-computer fields (location + objectives + counts), newest wins.
    @Published private(set) var objectives: Objectives?
    /// The marine's carried pack (Quake II only), newest wins; empty for Quake 1.
    @Published private(set) var inventory: [InventoryItem] = []
    /// Rolling log of recent center-print / damage events, newest last.
    @Published private(set) var events: [GameEvent] = []
    /// Wall-clock of the most recent packet of any kind.
    @Published private(set) var lastPacketAt: Date?
    /// Total packets ingested since launch (debug).
    @Published private(set) var packetCount = 0
    /// True while the feed is alive; flips false a few seconds after the game
    /// stops so we don't show stale vitals.
    @Published private(set) var live = false
    /// Increments on each damage event — drives the HUD CRT glitch.
    @Published private(set) var hitCount = 0
    /// Increments on death — flashes the digital skull.
    @Published private(set) var deathCount = 0
    /// Increments when HP crosses down into critical (≤10%) — flashes the skull
    /// and ramps the glitch/flicker.
    @Published private(set) var criticalCount = 0
    /// True from the moment the marine dies until a NEW game starts (fresh vitals
    /// with HP > 0). While dead, the HUD holds the cracked-glass overlay and a
    /// permanently-lit red skull, so a glance tells you the run ended.
    @Published private(set) var dead = false
    private var staleTask: Task<Void, Never>?

    private let maxEvents = 60

    /// Returns true when THIS device (the phone) should play game sounds — set
    /// by AppModel to "the watch isn't in use AND phone audio is enabled".
    var audioAllowed: () -> Bool = { false }

    /// True if a packet arrived within the last couple of seconds.
    var isReceiving: Bool {
        guard let lastPacketAt else { return false }
        return Date().timeIntervalSince(lastPacketAt) < 2.5
    }

    /// 0 when healthy, ramping to ~1 as HP nears 0 — drives glitch/flicker.
    var healthSeverity: Double {
        guard live, let hp = vitals?.hp, hp > 0, hp < 35 else { return 0 }
        return min(1, Double(35 - hp) / 35.0)
    }

    func apply(_ message: WireMessage) {
        packetCount += 1
        lastPacketAt = Date()
        resetIfNewSession()   // before markLive flips `live`, and before ingest
        markLive()
        switch message {
        case .vitals(let v):
            if let p = vitals {
                if p.hp > 0 && v.hp <= 0 && v.spec == 0 {
                    deathCount += 1
                    dead = true
                    if audioAllowed() { GameSounds.shared.play("glass_break") }
                } else if v.hp > 0 && v.hp <= 10 && p.hp > 10 {
                    criticalCount += 1
                }
            }
            // A new game / respawn (HP back above 0) clears the death overlays.
            if v.hp > 0 { dead = false }
            vitals = v
        case .meta(let m):
            // A new map/level wipes the stale transient log so last level's
            // "crouch here" etc. doesn't hang over. COMMS is derived from events.
            if let cur = meta, cur.level != m.level {
                events.removeAll(); objectives = nil; inventory = []
            }
            meta = m
        case .event(let e):
            // Engine-reported player sounds — play the exact effect (phone only
            // as a fallback when the watch isn't in use; see audioAllowed).
            if e.kind == "psound" {
                if let name = e.msg, !name.isEmpty, audioAllowed() {
                    GameSounds.shared.play(name)
                }
                return
            }
            if let o = e.asObjectives {
                objectives = o
                return
            }
            if e.isInventory {
                inventory = e.items ?? []
                return
            }
            if e.isDamage { hitCount += 1 }
            events.append(e)
            if events.count > maxEvents {
                events.removeFirst(events.count - maxEvents)
            }
        }
    }

    /// First packet of a fresh session (menu→game, reconnect, new game after the
    /// feed went quiet): drop any stale transient log so the previous game's COMMS
    /// (derived from events) / objectives don't hang over. Runs before ingest.
    private func resetIfNewSession() {
        guard !live else { return }
        events.removeAll()
        objectives = nil
        inventory = []
    }

    /// Single 1 Hz watchdog — avoids cancel/recreate churn on every packet.
    private func markLive() {
        live = true
        guard staleTask == nil else { return }
        staleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let last = lastPacketAt, Date().timeIntervalSince(last) > 4 {
                    live = false
                    staleTask = nil
                    return
                }
            }
        }
    }

    /// Clear transient state (e.g. when the listener restarts).
    func reset() {
        vitals = nil
        meta = nil
        objectives = nil
        inventory = []
        events.removeAll()
        lastPacketAt = nil
        packetCount = 0
        dead = false
    }
}
