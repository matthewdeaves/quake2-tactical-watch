//
//  WatchTransport.swift
//  Quake2TacticalWatchComputer
//
//  Shared contract for the phone→watch WatchConnectivity hop. Each wire message
//  is JSON-encoded to `Data` and shipped under a short key, so both sides reuse
//  the exact same Codable structs (WireProtocol.swift) — no hand-mapped
//  dictionaries to drift out of sync.
//
//  • vitals → updateApplicationContext (latest-wins, coalesced, survives lulls)
//  • meta   → updateApplicationContext (rarely changes; rides alongside vitals)
//  • event  → sendMessage when reachable (low-latency haptics), else transferUserInfo
//
//  Duplicated verbatim in the watch target.
//

import Foundation

nonisolated enum WatchTransport {
    /// Application-context key for the latest `Vitals` (JSON Data).
    static let vitalsKey = "v"
    /// Application-context key for the latest `Meta` (JSON Data).
    static let metaKey = "m"
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
