//
//  Haptics.swift
//  TacticalComputerWatchApp Watch App
//
//  Wrist feedback for game events, mapped to distinct WKInterfaceDevice haptics
//  so each event "feels" different without looking at the screen.
//

import Foundation
import WatchKit

enum Haptics {
    /// Persisted master toggle for wrist haptics. Default OFF: every watchOS
    /// haptic carries a small audible tone (it can't be separated from the buzz
    /// without putting the watch in Silent Mode), which the user found annoying.
    /// Mirrors @AppStorage("q2.haptics").
    static let defaultsKey = "q2.haptics"
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? false
    }

    private static func play(_ type: WKHapticType) {
        guard enabled else { return }
        WKInterfaceDevice.current().play(type)
    }

    /// Took damage — a firm, SILENT downward tap. (Was `.failure`, but that's one
    /// of watchOS's "musical" haptics: it emits an audible trill/shrill tone on
    /// every hit, which sounds like a system beep. The directional/click/stop
    /// haptics are pure taps with no tone.)
    static func damage()    { play(.directionDown) }

    /// Died (health hit 0) — heavy stop.
    static func death()     { play(.stop) }

    /// Health just dropped into the critical band (≤25) — downward warning.
    static func lowHealth() { play(.directionDown) }

    /// Scored a frag — crisp success tick.
    static func frag()      { play(.success) }

    /// Picked up a powerup — notification.
    static func powerup()   { play(.notification) }

    /// Picked something up / story center-print — light click.
    static func pickup()    { play(.click) }
}
