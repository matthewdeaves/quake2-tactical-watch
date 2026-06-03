//
//  GameSounds.swift
//  Quake2TacticalWatchComputer
//
//  iPhone-side playback of the real Quake II effects (38 clips bundled by game
//  basename). Driven by the engine's "psound" events. The watch normally owns
//  audio; the phone only plays when the watch isn't in use (AppModel gates on
//  watch reachability), so you still hear sounds without the watch on.
//

import Foundation
import AVFoundation

@MainActor
final class GameSounds {
    static let shared = GameSounds()
    /// Persisted output level 0…1 (default full); shared key with the watch.
    static let volumeKey = "q2.volume"
    /// Persisted "play the *jump grunt" toggle (default OFF). Some players find it
    /// chatty, so it's silenced unless explicitly switched on.
    static let jumpKey = "q2.jumpSound"

    private var players: [String: AVAudioPlayer] = [:]

    private init() {}   // BackgroundAudio owns the shared AVAudioSession.

    /// Output level 0…1. Read defensively: `object(forKey:) as? Double` can fail
    /// to bridge the stored NSNumber (which silently pinned us to 1.0); using
    /// `double(forKey:)` with an explicit "is it set?" check is bullet-proof.
    private var volume: Float {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.volumeKey) != nil else { return 1.0 }
        return Float(d.double(forKey: Self.volumeKey))
    }

    private var jumpEnabled: Bool { UserDefaults.standard.object(forKey: Self.jumpKey) as? Bool ?? false }

    /// Play the sound for a game basename, with category fallback. Only the *jump
    /// grunt is individually mutable; the help-computer "objectives updated" voice
    /// (pc_up) always plays when the game triggers it — it's in-fiction important.
    func play(_ name: String) {
        guard volume > 0 else { return }
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
        if n.hasPrefix("damage") { return "damage" }
        if n.hasPrefix("protect") { return "protect" }
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
