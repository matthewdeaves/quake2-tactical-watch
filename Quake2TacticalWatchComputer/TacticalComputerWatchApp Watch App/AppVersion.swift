//
//  AppVersion.swift
//  TacticalComputerWatchApp Watch App
//
//  Human-readable build stamp, e.g. "v1.0 (20260603.2010)". The build number is
//  stamped with a timestamp at build time so you can confirm which build is on
//  the wrist. The watch reports this to the phone over WatchConnectivity too.
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
