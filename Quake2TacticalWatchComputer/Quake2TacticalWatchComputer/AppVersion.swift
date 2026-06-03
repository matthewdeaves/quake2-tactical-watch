//
//  AppVersion.swift
//  Quake2TacticalWatchComputer
//
//  Human-readable build stamp, e.g. "v1.0 (20260603.2010)". The build number is
//  stamped with a timestamp at build time (CURRENT_PROJECT_VERSION override) so
//  you can confirm exactly which build is running on each device.
//

import Foundation

enum AppVersion {
    static var string: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }
}
