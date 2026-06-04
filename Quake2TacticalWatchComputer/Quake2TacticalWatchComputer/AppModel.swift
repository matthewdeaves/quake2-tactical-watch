//
//  AppModel.swift
//  Quake2TacticalWatchComputer
//
//  Composition root for the phone app: owns the UDP listener, the game-state
//  model, and the watch relay, and stitches them together. Injected into the
//  SwiftUI environment by the app entry point.
//

import Foundation
import Combine

@MainActor
final class AppModel: ObservableObject {
    let gameState = GameState()
    let listener = UDPListener()
    let relay = WatchRelay()
    let backgroundAudio = BackgroundAudio()

    /// UDP port the phone listens on; matches the engine's `watch_port`.
    @Published var port: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(port), forKey: Self.portKey)
            if isListening { startListening() }
        }
    }

    @Published private(set) var isListening = false

    private static let portKey = "watchlink.port"
    static let defaultPort: UInt16 = 27999

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.portKey)
        self.port = (stored > 0 && stored <= 65535) ? UInt16(stored) : Self.defaultPort

        // Forward every decoded packet into the model and across to the watch.
        listener.onMessage = { [weak self] message in
            guard let self else { return }
            self.gameState.apply(message)
            self.relay.forward(message)
        }

        // Where do game sounds play? Sound only ever comes out of ONE device.
        //   • "Play audio on iPhone" OFF (default): the watch owns audio while
        //     it's in use; the phone plays only as a FALLBACK when the watch
        //     isn't in use (not on the wrist / app not running). `watchInUse`
        //     survives Always-On dimming, so we don't double-play wrist-down.
        //   • "Play audio on iPhone" ON: the phone ALWAYS plays (handy for
        //     screen-recording a demo so the recording captures the sound), and
        //     the watch is told to stay silent (phoneOwnsAudioKey in the context).
        gameState.audioAllowed = { [weak self] in
            guard let self else { return false }
            if Self.forcePhoneAudio { return true }   // forced: phone always plays
            return !self.relay.watchInUse             // default: phone is the fallback
        }
        // Keep the watch's mute state in lockstep with the toggle.
        relay.phoneOwnsAudio = { Self.forcePhoneAudio }
    }

    /// "Play audio on iPhone" — when true the phone owns audio and the watch is
    /// muted; when false (default) the watch owns it and the phone is fallback.
    static let forcePhoneAudioKey = "q2.forcePhoneAudio"
    static var forcePhoneAudio: Bool {
        UserDefaults.standard.object(forKey: forcePhoneAudioKey) as? Bool ?? false
    }

    /// Re-push the audio routing to the watch immediately when the toggle flips,
    /// so the watch mutes/unmutes without waiting for the next vitals heartbeat.
    func audioRoutingChanged() { relay.pushContextNow() }

    private var relayActivated = false

    func onAppLaunch() {
        if !relayActivated {            // WCSession should be activated once
            relay.activate()
            relayActivated = true
        }
        startListening()
        // Keep the relay alive with the phone locked / app backgrounded.
        backgroundAudio.start()
    }

    func startListening() {
        // Idempotent: don't tear down a listener that's already live/coming up
        // on the same port (that race caused the "press Start" symptom).
        switch listener.status {
        case .listening(let p) where p == port: isListening = true; return
        case .waiting: isListening = true; return
        default: break
        }
        listener.start(port: port)
        isListening = true
    }

    func stopListening() {
        listener.stop()
        isListening = false
    }
}
