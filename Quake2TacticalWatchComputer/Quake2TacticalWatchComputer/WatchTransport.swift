//
//  WatchTransport.swift
//  Quake2TacticalWatchComputer
//
//  Shared contract for the phone→watch WatchConnectivity hop. Each wire message
//  is JSON-encoded to `Data` and shipped under a short key, so both sides reuse
//  the exact same Codable structs (WireProtocol.swift) — no hand-mapped
//  dictionaries to drift out of sync.
//
//  • vitals/meta/inventory/objectives → updateApplicationContext
//        (latest-wins, coalesced, ALWAYS lands when the watch next wakes)
//  • transient events (damage/centerprint/psound) → sendMessage when reachable
//        (low-latency haptics/SFX), dropped otherwise — never queued.
//
//  Duplicated verbatim in the watch target.
//

import Foundation

nonisolated enum WatchTransport {
    /// Application-context key for the latest `Vitals` (JSON Data).
    static let vitalsKey = "v"
    /// Application-context key for the latest `Meta` (JSON Data).
    static let metaKey = "m"
    /// Application-context key for the latest inventory ([InventoryItem] JSON
    /// Data). Rides the context (latest-wins) — it's state, not a transient
    /// event, so it must survive the watch being briefly unreachable.
    static let inventoryKey = "i"
    /// Application-context key for the latest `Objectives` (JSON Data). Like
    /// inventory, the F1 mission/kills/secrets are latest-wins STATE, not a
    /// transient effect — so they ride the coalesced context and ALWAYS land,
    /// instead of going via sendMessage (which is dropped when the watch isn't
    /// reachable at that instant). The engine only re-sends objectives when the
    /// F1 layout changes, so one dropped message used to leave the watch blank
    /// until the next change.
    static let objectivesKey = "o"
    /// Application-context key (Bool) telling the watch the PHONE currently owns
    /// audio, so the watch must stay silent — sound only ever plays on ONE
    /// device. Set when the iPhone's "play audio on iPhone" toggle is on (e.g.
    /// for screen recording). Rides the context so the watch always has the
    /// current routing. Absent/false ⇒ the watch plays as normal.
    static let phoneOwnsAudioKey = "pa"
    /// Application-context keys (Bool) for the WATCH's own preferences. These are
    /// now set on the iPhone (Setup → Audio / Watch) to reduce on-wrist clutter,
    /// and pushed to the watch, which persists each into its OWN UserDefaults so
    /// GameSounds/Haptics keep reading them exactly as before. The key strings ARE
    /// the watch's UserDefaults keys, so the watch writes them straight through.
    /// (Volume stays on the watch and is NOT pushed.)
    static let watchSoundKey = "q2.sound"        // game-sounds master
    static let watchJumpKey = "q2.jumpSound"     // jump grunt
    static let watchHapticsKey = "q2.haptics"    // wrist haptics
    /// Message/userInfo key for a discrete `GameEvent` (JSON Data).
    static let eventKey = "e"

    static func encode<T: Encodable>(_ value: T) -> Data? {
        try? JSONEncoder().encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from any: Any?) -> T? {
        guard let data = any as? Data else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
