//
//  GameSounds.swift
//  TacticalComputerWatchApp Watch App
//
//  Plays the real Quake II sound effects (extracted from the game's own
//  pak0.pak, 38 clips bundled by their game basename). The ENGINE tells us
//  exactly which sound the local player triggered via a "psound" event; we look
//  up the matching WAV and play it. Mixes with other audio; respects a mute.
//

import Foundation
import AVFoundation

@MainActor
final class GameSounds {
    static let shared = GameSounds()

    /// Persisted mute toggle (default ON). Mirrors @AppStorage("q2.sound").
    static let defaultsKey = "q2.sound"
    /// Persisted output level 0…1 (default full). Mirrors @AppStorage("q2.volume").
    static let volumeKey = "q2.volume"
    /// Persisted "play the *jump grunt" toggle (default OFF — some players find it
    /// chatty). Mirrors @AppStorage("q2.jumpSound").
    static let jumpKey = "q2.jumpSound"

    private var players: [String: AVAudioPlayer] = [:]

    private init() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, options: [.mixWithOthers])
        try? session.setActive(true)   // once — not per sound
    }

    private var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    /// Output level 0…1. Read defensively: `object(forKey:) as? Double` can fail
    /// to bridge the stored NSNumber (which silently pinned us to full volume);
    /// using `double(forKey:)` with an explicit "is it set?" check is bullet-proof.
    private var volume: Float {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.volumeKey) != nil else { return 1.0 }
        return Float(d.double(forKey: Self.volumeKey))
    }

    private var jumpEnabled: Bool { UserDefaults.standard.object(forKey: Self.jumpKey) as? Bool ?? false }

    /// Play the sound for a game basename (e.g. "jump1", "pain50_1", "w_pkup",
    /// "s_health", "damage"). Exact bundle match preferred; otherwise a sensible
    /// category fallback. Honours the master mute; only the *jump grunt is
    /// individually mutable. The help-computer "objectives updated" voice (pc_up)
    /// is always played when the game triggers it — it's in-fiction important.
    func play(_ name: String) {
        guard enabled, volume > 0 else { return }
        let n = name.lowercased()
        if n.hasPrefix("jump") && !jumpEnabled { return }       // *jump grunt
        guard let p = player(for: resolve(name)) else { return }
        p.volume = volume
        p.currentTime = 0
        p.play()
    }

    private func resolve(_ name: String) -> String {
        if Bundle.main.url(forResource: name, withExtension: "wav") != nil { return name }
        let n = name.lowercased()
        if n.hasPrefix("pain") { return "pain50_1" }
        if n.hasPrefix("death") || n.hasPrefix("drown") { return "death1" }
        if n.hasPrefix("fall") { return "fall1" }
        if n.hasPrefix("gurp") || n.hasPrefix("airout") { return "gurp1" }
        if n.contains("health") { return "s_health" }
        if n.contains("pkup") { return "w_pkup" }
        if n.hasPrefix("damage") { return "damage" }    // Quad
        if n.hasPrefix("protect") { return "protect" }  // Invulnerability
        return name
    }

    private func player(for file: String) -> AVAudioPlayer? {
        if let p = players[file] { return p }
        guard let url = Bundle.main.url(forResource: file, withExtension: "wav"),
              let p = try? AVAudioPlayer(contentsOf: url) else { return nil }
        p.prepareToPlay()
        players[file] = p
        return p
    }
}
