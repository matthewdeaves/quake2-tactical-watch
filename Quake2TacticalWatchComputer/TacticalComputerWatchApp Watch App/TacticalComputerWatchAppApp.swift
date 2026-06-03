//
//  TacticalComputerWatchAppApp.swift
//  TacticalComputerWatchApp Watch App
//
//  The on-wrist Quake II "tactical computer".
//

import SwiftUI

@main
struct TacticalComputerWatchApp_Watch_AppApp: App {
    @StateObject private var connector = WatchConnector()
    @State private var keepAwake = WorkoutKeepAlive()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connector)
                .environment(keepAwake)
                .onAppear { connector.activate() }
                .onChange(of: connector.live) { _, live in
                    // Start recording the workout (and hold the screen awake)
                    // ONLY when a game actually begins — never just on app open.
                    if live { keepAwake.start() }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            // On return to the app, re-arm only if a game is still live (recovers
            // a session invalidated while backgrounded). Never auto-END — only the
            // WORKOUT screen's End button stops & saves, like a real Health app.
            if phase == .active && connector.live { keepAwake.start() }
        }
    }
}
