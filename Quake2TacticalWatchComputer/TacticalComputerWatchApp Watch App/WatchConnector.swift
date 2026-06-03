//
//  WatchConnector.swift
//  TacticalComputerWatchApp Watch App
//
//  Watch side of the WatchConnectivity bridge. Receives vitals/meta via the
//  application context and discrete events via messages, decodes them with the
//  shared Codable structs, and publishes them to the UI. Fires a haptic on
//  damage events.
//

import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WatchConnector: NSObject, ObservableObject {
    @Published private(set) var vitals: Vitals?
    @Published private(set) var meta: Meta?
    /// All events (used for haptics). The COMMS screen shows only the messages.
    @Published private(set) var events: [GameEvent] = []
    /// Story / pickup center-print messages — the meaningful comms log.
    @Published private(set) var comms: [GameEvent] = []
    /// The F1 help-computer fields (location + objectives + counts), newest wins.
    @Published private(set) var objectives: Objectives?
    @Published private(set) var lastUpdate: Date?

    /// Briefly true right after a damage event so the UI can flash red.
    @Published var damageFlash = false
    /// Increments on each hit — drives the CRT glitch on the screen.
    @Published private(set) var hitCount = 0
    /// Increments on death — flashes the digital skull overlay.
    @Published private(set) var deathCount = 0
    /// Increments when health crosses down into critical (≤10%) — also flashes
    /// the skull, and ramps up the glitch/flicker the lower it gets.
    @Published private(set) var criticalCount = 0
    /// True from death until a NEW game starts (fresh vitals HP > 0). While dead,
    /// the watch holds the cracked-glass overlay + a permanently-lit red skull.
    @Published private(set) var dead = false

    /// True while the feed is alive (a packet arrived within the last few
    /// seconds). Goes false when the game stops, so we don't show stale vitals.
    @Published private(set) var live = false
    private var staleTask: Task<Void, Never>?

    private let maxEvents = 40
    private var lastFlashes = 0

    var isReceiving: Bool {
        guard let lastUpdate else { return false }
        return Date().timeIntervalSince(lastUpdate) < 3.0
    }

    /// 0 when healthy, ramping to ~1 as HP nears 0 — drives how violent the CRT
    /// glitch and UI flicker get. Zero unless we have a live, wounded marine.
    var healthSeverity: Double {
        guard live, let hp = vitals?.hp, hp > 0, hp < 35 else { return 0 }
        return min(1, Double(35 - hp) / 35.0)
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    // MARK: - Apply incoming data (main actor)

    fileprivate func applyContext(_ context: [String: Any]) {
        resetIfNewSession()
        if let v = WatchTransport.decode(Vitals.self, from: context[WatchTransport.vitalsKey]) {
            ingestVitals(v)
        }
        if let m = WatchTransport.decode(Meta.self, from: context[WatchTransport.metaKey]) {
            // A new map/level wipes the stale transient log (COMMS / objectives),
            // so last level's "crouch here" etc. doesn't hang over.
            if let cur = meta, cur.level != m.level {
                comms.removeAll(); events.removeAll(); objectives = nil
            }
            meta = m
        }
        lastUpdate = Date()
        markLive()
        pingPhoneAlive()
    }

    /// First packet of a fresh session (menu→game, reconnect, new game after the
    /// feed went quiet): drop any stale transient log so the previous game's
    /// COMMS / objectives don't hang over into the new one. Runs BEFORE ingest so
    /// a new session's own first message is preserved.
    private func resetIfNewSession() {
        guard !live else { return }
        comms.removeAll()
        events.removeAll()
        objectives = nil
    }

    /// Tell the phone the watch is actively showing the game, so the phone mutes
    /// its FALLBACK audio and we never double-play. The vitals stream is the most
    /// reliable "watch in use" signal — it keeps flowing even in Always-On (wrist
    /// down), unlike `isReachable`. Throttled; sendMessage when reachable (instant)
    /// else transferUserInfo (guaranteed, survives background — and doesn't clobber
    /// the heart-rate application context).
    private var lastAlivePing: Date?
    private func pingPhoneAlive() {
        let now = Date()
        if let last = lastAlivePing, now.timeIntervalSince(last) < 2 { return }
        lastAlivePing = now
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        if s.isReachable {
            s.sendMessage(["alive": 1], replyHandler: nil, errorHandler: nil)
        } else {
            s.transferUserInfo(["alive": 1])
        }
    }

    fileprivate func applyMessage(_ message: [String: Any]) {
        resetIfNewSession()
        if let e = WatchTransport.decode(GameEvent.self, from: message[WatchTransport.eventKey]) {
            ingestEvent(e)
        }
        lastUpdate = Date()
        markLive()
    }

    /// Mark the feed alive. A SINGLE long-lived watchdog (1 Hz) flips it dead
    /// after a few seconds of silence — avoids cancel/recreate churn on every
    /// 10 Hz packet.
    private func markLive() {
        live = true
        guard staleTask == nil else { return }
        staleTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if let last = lastUpdate, Date().timeIntervalSince(last) > 4 {
                    live = false
                    staleTask = nil
                    return
                }
            }
        }
    }

    private func ingestVitals(_ v: Vitals) {
        let prev = vitals

        // Damage edge from the STAT_FLASHES bitfield (also a fallback if a
        // discrete damage event was dropped).
        if v.flashes & ~lastFlashes != 0 {
            triggerDamage()
        }
        lastFlashes = v.flashes

        // Transition-driven haptics + Quake II sounds so the wrist tells the
        // story eyes-free.
        // HAPTICS are client-detected here; SOUNDS come from the engine's
        // "psound" events (see ingestEvent) so they match exactly what played.
        if let p = prev {
            if p.hp > 0 && v.hp <= 0 && v.spec == 0 {
                Haptics.death()
                GameSounds.shared.play("glass_break")   // screen-crack SFX
                deathCount += 1
                dead = true
            } else if v.hp > 0 && v.hp <= 10 && p.hp > 10 {
                // Crossed into critical — flash the skull and buzz hard.
                Haptics.lowHealth()
                criticalCount += 1
            } else if p.hp > 25 && v.hp <= 25 && v.hp > 0 {
                Haptics.lowHealth()
            }
            if p.hp > 0 && v.hp > p.hp { Haptics.pickup() }   // health pickup
            if v.frags > p.frags { Haptics.frag() }
            if v.pu.isActive && !p.pu.isActive { Haptics.powerup() }
        }

        // A new game / respawn (HP back above 0) clears the death overlays.
        if v.hp > 0 { dead = false }
        vitals = v
    }

    private func ingestEvent(_ e: GameEvent) {
        // Player sounds: play the exact Quake II effect the engine reported.
        if e.kind == "psound" {
            if let name = e.msg, !name.isEmpty { GameSounds.shared.play(name) }
            return
        }
        // F1 help-computer fields (location + objectives + counts).
        if let o = e.asObjectives {
            objectives = o
            return
        }

        events.append(e)
        if events.count > maxEvents { events.removeFirst(events.count - maxEvents) }

        if e.isDamage {
            triggerDamage()
        } else if e.isCenterprint, let msg = e.msg, !msg.isEmpty {
            // Real comms (pickups, story, objectives) — log it and tick.
            comms.append(e)
            if comms.count > maxEvents { comms.removeFirst(comms.count - maxEvents) }
            Haptics.pickup()
        }
    }

    private var lastDamageAt: Date?
    private var flashTask: Task<Void, Never>?

    private func triggerDamage() {
        // The same hit can arrive on both the discrete event AND the vitals
        // flashes edge — debounce so we buzz once.
        let now = Date()
        if let last = lastDamageAt, now.timeIntervalSince(last) < 0.15 { return }
        lastDamageAt = now

        Haptics.damage()
        hitCount += 1
        damageFlash = true
        // Single owner of the flash window so overlapping hits don't clear it early.
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            if !Task.isCancelled { self.damageFlash = false }
        }
    }
}

extension WatchConnector: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // NB: deliberately DO NOT replay session.receivedApplicationContext here.
        // WatchConnectivity persists the *last* context across launches, so
        // applying it on activation would show stale vitals from a previous match
        // (and spuriously flip `live` true, auto-starting a workout) when no game
        // is running. We stay on "AWAITING UPLINK" until a FRESH push arrives —
        // a live game pushes new vitals within ~100 ms, so there's no real delay.
        if activationState == .activated {
            session.transferUserInfo(["watchVersion": AppVersion.string])
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.applyContext(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.applyMessage(message) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in self.applyMessage(userInfo) }
    }
}
