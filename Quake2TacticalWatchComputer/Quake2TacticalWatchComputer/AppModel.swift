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

        // The phone plays game sounds only as a FALLBACK: when the watch isn't in
        // use (not on the wrist / app not running) and phone audio is enabled
        // (default on). `watchInUse` survives Always-On dimming, so we don't
        // double-play while the player's wrist is down. The watch owns audio.
        gameState.audioAllowed = { [weak self] in
            guard let self else { return false }
            let phoneOn = UserDefaults.standard.object(forKey: Self.phoneSoundKey) as? Bool ?? true
            return phoneOn && !self.relay.watchInUse
        }
    }

    static let phoneSoundKey = "q2.phoneSound"

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
