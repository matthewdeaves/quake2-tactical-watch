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
            latestMeta = m
            pushContext()
        case .event(let e):
            sendEvent(e)
        }
    }

    // MARK: - Sending

    /// Coalesced latest-wins state. WCSession throttles these for us, so even at
    /// 10 Hz only the freshest snapshot lands on the watch.
    private func pushContext() {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        // Don't push (and silently throw ~10×/s) until the watch app is a
        // reachable companion.
        guard s.activationState == .activated, s.isWatchAppInstalled else { return }
        var ctx: [String: Any] = [:]
        if let v = latestVitals, let d = WatchTransport.encode(v) {
            ctx[WatchTransport.vitalsKey] = d
        }
        if let m = latestMeta, let d = WatchTransport.encode(m) {
            ctx[WatchTransport.metaKey] = d
        }
        guard !ctx.isEmpty else { return }
        do {
            try WCSession.default.updateApplicationContext(ctx)
            contextUpdates += 1
        } catch {
            // Non-fatal: the next heartbeat will try again.
        }
    }

    private func sendEvent(_ event: GameEvent) {
        guard WCSession.isSupported(), let d = WatchTransport.encode(event) else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isWatchAppInstalled else { return }
        let payload = [WatchTransport.eventKey: d]
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // Delivery failed (watch went away mid-send) — queue it instead.
                Task { @MainActor in WCSession.default.transferUserInfo(payload) }
            }
        } else {
            // Not reachable: queue for guaranteed background delivery.
            session.transferUserInfo(payload)
        }
        eventsSent += 1   // counted once, at enqueue
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
        Task { @MainActor in self.refreshState(session) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.refreshState(session) }
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
