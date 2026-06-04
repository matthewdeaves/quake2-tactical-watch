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

    /// Unified "Game sounds" master (shared key with the watch, set in iPhone
    /// Setup). Off ⇒ no game sounds on EITHER device (haptics still fire).
    private var soundEnabled: Bool { UserDefaults.standard.object(forKey: "q2.sound") as? Bool ?? true }

    /// Play the sound for a game basename, with category fallback. Only the *jump
    /// grunt is individually mutable; the help-computer "objectives updated" voice
    /// (pc_up) always plays when the game triggers it — it's in-fiction important.
    /// Play the effect for a game basename. `isQuake1` selects the game-correct
    /// clip set: Quake 1 sounds are bundled q1_-prefixed so they never collide
    /// with the Quake II set (both ship a "damage"/"death1" of different vintage).
    func play(_ name: String, isQuake1: Bool = false) {
        guard soundEnabled, volume > 0 else { return }
        let n = name.lowercased()
        // The chatty jump grunt is opt-in (Q2 "*jump…", Q1 "plyrjmp8").
        if (n.hasPrefix("jump") || n.hasPrefix("plyrjmp")) && !jumpEnabled { return }
        guard let p = player(for: resolve(n, isQuake1: isQuake1)) else { return }
        p.volume = volume
        p.currentTime = 0
        p.play()
    }

    private func has(_ file: String) -> Bool {
        Bundle.main.url(forResource: file, withExtension: "wav") != nil
    }

    private func resolve(_ name: String, isQuake1: Bool) -> String {
        if isQuake1 {
            let q = "q1_" + name
            if has(q) { return q }
            // Category fallbacks (all q1_-prefixed) for anything not bundled.
            if name.hasPrefix("pain") { return "q1_pain1" }
            if name.hasPrefix("death") || name.hasPrefix("udeath") || name == "gib" || name.hasPrefix("teledth") { return "q1_death1" }
            if name.hasPrefix("drown") || name.contains("h2odeath") || name.hasPrefix("gasp") { return "q1_drown1" }
            if name.contains("inv") { return "q1_inv1" }
            if name.hasPrefix("protect") { return "q1_protect" }
            if name.hasPrefix("damage") { return "q1_damage" }
            if name.contains("health") || name.contains("armor") || name.contains("item") || name.contains("pkup") { return "q1_pkup" }
            if has(name) { return name }     // app SFX (e.g. glass_break)
            return "q1_pkup"
        }
        // Quake II (default).
        if has(name) { return name }
        if name.hasPrefix("pain") { return "pain50_1" }
        if name.hasPrefix("death") || name.hasPrefix("drown") { return "death1" }
        if name.hasPrefix("fall") { return "fall1" }
        if name.hasPrefix("gurp") || name.hasPrefix("airout") { return "gurp1" }
        if name.contains("health") { return "s_health" }
        if name.contains("pkup") { return "w_pkup" }
        if name.hasPrefix("damage") { return "damage" }
        if name.hasPrefix("protect") { return "protect" }
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
