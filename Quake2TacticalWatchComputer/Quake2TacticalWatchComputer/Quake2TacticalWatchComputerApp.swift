//
//  Quake2TacticalWatchComputerApp.swift
//  Quake2TacticalWatchComputer
//
//  iPhone relay app: receives the engine's UDP feed and bridges it to the watch.
//

import SwiftUI

@main
struct Quake2TacticalWatchComputerApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.gameState)
                .environmentObject(model.listener)
                .environmentObject(model.relay)
        }
        // Single launch/foreground driver (avoids the onAppear + scenePhase
        // double-start that raced the Local Network permission flow). Fires
        // .active on first launch and on every return to foreground; the work
        // is idempotent so re-arming a live listener is a no-op.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.onAppLaunch() }
        }
    }
}
