//
//  WatchRelay.swift
//  Quake2TacticalWatchComputer
//
//  Phone side of the WatchConnectivity bridge. Forwards the decoded feed to the
//  paired watch:
//    • vitals/meta → updateApplicationContext (latest-wins, coalesced)
//    • events      → sendMessage when reachable (low latency), else transferUserInfo
//

import Foundation
import Combine
import WatchConnectivity

@MainActor
final class WatchRelay: NSObject, ObservableObject {

    @Published private(set) var isSupported = WCSession.isSupported()
    @Published private(set) var isPaired = false
    @Published private(set) var isWatchAppInstalled = false
    @Published private(set) var isReachable = false
    @Published private(set) var contextUpdates = 0
    @Published private(set) var eventsSent = 0
    @Published private(set) var lastSync = ""
    @Published private(set) var watchVersion = ""   // reported by the watch app
    @Published private(set) var heartRate = 0        // live BPM from the watch

    private var latestVitals: Vitals?
    private var latestMeta: Meta?
    private var latestInventory: [InventoryItem]?
    private var latestObjectives: Objectives?

    /// Whether the PHONE currently owns audio (so the watch must stay silent).
    /// Injected by AppModel from the "play audio on iPhone" toggle; rides every
    /// real context push so the watch's mute state tracks the toggle.
    var phoneOwnsAudio: () -> Bool = { false }

    /// When the watch last sent us ANYTHING (vitals-ack ping, heart rate, …).
    /// `isReachable` alone is unreliable: it drops to false whenever the watch
    /// dims to Always-On or the wrist falls — which happens constantly while the
    /// player's hands are on the keyboard. So we treat the watch as "in use" if
    /// it's reachable OR we've heard from it within a short grace window.
    private var lastWatchContact = Date.distantPast
    private func noteContact() { lastWatchContact = Date() }

    /// True while the watch is actively showing the game — used to suppress the
    /// phone's fallback audio so we never double-play.
    var watchInUse: Bool {
        if isReachable { return true }
        return Date().timeIntervalSince(lastWatchContact) < 6
    }

    func activate() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        s.delegate = self
        s.activate()
    }

    /// Re-arm the link and shove the freshest known snapshot at the watch right
    /// now. NOTE: this does NOT (and cannot) install the watch app — iOS has no
    /// API for that; installs are owned by the system / Watch app. This just
    /// guarantees the watch has current data the moment it's reachable, and
    /// surfaces exactly why the link isn't live if it isn't.
    func syncNow() {
        activate()
        let s = WCSession.default
        refreshState(s)
        pushContext()

        if !WCSession.isSupported() {
            lastSync = "WatchConnectivity unsupported"
        } else if !s.isPaired {
            lastSync = "no watch paired"
        } else if !s.isWatchAppInstalled {
            lastSync = "watch app not installed yet"
        } else if s.isReachable {
            lastSync = "synced — watch reachable"
        } else {
            lastSync = "queued — watch app installed, not in foreground"
        }
    }

    func forward(_ message: WireMessage) {
        switch message {
        case .vitals(let v):
            latestVitals = v
            pushContext()
        case .meta(let m):
            // New map: drop last level's latest-wins state so the coalesced
            // context can't carry stale objectives/inventory into the new level
            // before the engine resends them (the watch also clears on its side).
            if latestMeta?.level != m.level {
                latestObjectives = nil
                latestInventory = nil
            }
            latestMeta = m
            pushContext()
        case .event(let e):
            // Inventory and objectives are latest-wins STATE, not transient
            // effects: route them through the coalesced app context (like vitals)
            // so they ALWAYS land — surviving the watch being briefly unreachable
            // — instead of being dropped with the real-time event stream below.
            // The engine only re-sends objectives when the F1 layout changes, so
            // a single dropped sendMessage used to leave the watch's MISSION page
            // blank until the next change. This is that fix.
            if e.isInventory {
                latestInventory = e.items ?? []
                pushContext()
            } else if let o = e.asObjectives {
                latestObjectives = o
                pushContext()
            } else {
                sendEvent(e)
            }
        }
    }

    // MARK: - Sending

    /// Coalesced latest-wins state. WCSession throttles these for us, so even at
    /// 10 Hz only the freshest snapshot lands on the watch.
    private func pushContext() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        // Only require an ACTIVATED session. We deliberately DON'T gate on
        // isWatchAppInstalled: after a dev/sideload install (Xcode/devicectl) that
        // companion flag can read false even though the watch app IS installed and
        // running, which would silently block the ENTIRE vitals feed and leave the
        // watch stuck on STANDBY. updateApplicationContext is safe to call whenever
        // the session is activated — it just stores the latest snapshot for the
        // watch to pick up, and the catch below swallows the rare not-activated throw.
        guard s.activationState == .activated else { return }
        var ctx: [String: Any] = [:]
        if let v = latestVitals, let d = WatchTransport.encode(v) {
            ctx[WatchTransport.vitalsKey] = d
        }
        if let m = latestMeta, let d = WatchTransport.encode(m) {
            ctx[WatchTransport.metaKey] = d
        }
        if let inv = latestInventory, let d = WatchTransport.encode(inv) {
            ctx[WatchTransport.inventoryKey] = d
        }
        if let o = latestObjectives, let d = WatchTransport.encode(o) {
            ctx[WatchTransport.objectivesKey] = d
        }
        guard !ctx.isEmpty else { return }
        // Real state present — ride the current audio routing along so the watch
        // mutes when the phone owns audio (and unmutes when it doesn't). Added
        // AFTER the empty check so a routing flag alone never pushes (and never
        // spuriously flips the watch "live" with no vitals).
        ctx[WatchTransport.phoneOwnsAudioKey] = phoneOwnsAudio()
        // Push the watch-side prefs now set on the iPhone (game sounds / jump /
        // haptics) so the watch honours them; volume stays watch-local (not sent).
        let prefs = UserDefaults.standard
        ctx[WatchTransport.watchSoundKey] = prefs.object(forKey: WatchTransport.watchSoundKey) as? Bool ?? true
        ctx[WatchTransport.watchJumpKey] = prefs.object(forKey: WatchTransport.watchJumpKey) as? Bool ?? false
        ctx[WatchTransport.watchHapticsKey] = prefs.object(forKey: WatchTransport.watchHapticsKey) as? Bool ?? false
        do {
            try WCSession.default.updateApplicationContext(ctx)
            contextUpdates += 1
        } catch {
            // Non-fatal: the next heartbeat will try again.
        }
    }

    /// Public trigger to re-push the latest context immediately — used when the
    /// "play audio on iPhone" toggle flips so the watch mutes/unmutes at once
    /// instead of waiting for the next vitals heartbeat.
    func pushContextNow() { pushContext() }

    private func sendEvent(_ event: GameEvent) {
        guard WCSession.isSupported(), let d = WatchTransport.encode(event) else { return }
        let session = WCSession.default
        // As with pushContext, don't gate on isWatchAppInstalled (unreliable after
        // a sideload install); reachability is the real gate for live messages.
        guard session.activationState == .activated else { return }
        // Events (sounds, damage, story, objectives) are REAL-TIME. If the watch
        // isn't reachable this instant, DROP them — never queue via
        // transferUserInfo: that guarantees delivery, so a whole iPhone-only
        // session's backlog would dump onto the watch the moment it connects and
        // replay every sound at once. The watch picks the feed back up live (and
        // vitals always ride the latest-wins app context, so state stays correct).
        guard session.isReachable else { return }
        session.sendMessage([WatchTransport.eventKey: d], replyHandler: nil, errorHandler: nil)
        eventsSent += 1
    }

    private func refreshState(_ session: WCSession) {
        isPaired = session.isPaired
        isWatchAppInstalled = session.isWatchAppInstalled
        isReachable = session.isReachable
    }
}

// WCSessionDelegate callbacks arrive on a background thread, so they must be
// nonisolated; each hops back to the main actor to touch @Published state.
extension WatchRelay: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.refreshState(session)
            self.pushContext()   // hand the watch the freshest state on (re)connect
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Reactivate to support switching between paired watches.
        WCSession.default.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshState(session)
            // The companion (re)appeared / installed / became active — hand it the
            // freshest snapshot right now instead of waiting for the next packet.
            self.pushContext()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.refreshState(session)
            // Watch just came within reach — push current state immediately so it
            // lights up at once rather than after the next ~1 s vitals heartbeat.
            self.pushContext()
        }
    }

    // The watch reports its build version + alive-pings via transferUserInfo.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        Task { @MainActor in
            self.noteContact()
            if let v = userInfo["watchVersion"] as? String { self.watchVersion = v }
        }
    }

    // The watch streams its live heart rate + alive-pings — message when reachable,
    // else its application context (fallback). Any inbound traffic = "watch in use".
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            self.noteContact()
            if let hr = message["hr"] as? Int { self.heartRate = hr }
        }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in
            self.noteContact()
            if let hr = applicationContext["hr"] as? Int { self.heartRate = hr }
        }
    }
}
