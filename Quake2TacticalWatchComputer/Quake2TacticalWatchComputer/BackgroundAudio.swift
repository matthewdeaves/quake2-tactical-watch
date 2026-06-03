//
//  BackgroundAudio.swift
//  Quake2TacticalWatchComputer
//
//  Keeps the UDP relay alive while the phone is LOCKED or the app is in the
//  background. iOS suspends a normal app shortly after it backgrounds, tearing
//  down the NWListener socket and the Bonjour advertisement — so the engine
//  loses the phone and the watch goes dark the moment you pocket it.
//
//  The fix: hold an audio session and loop a *sub-audible* (tiny, non-zero)
//  tone. A pure-silent buffer is an unreliable "now playing" signal — iOS can
//  treat an all-silent render as idle and suspend us anyway — so we write a
//  ~1e-4 amplitude wave (inaudible) to guarantee the route stays active. With
//  the `audio` UIBackgroundMode declared, iOS then keeps the process running
//  with the phone in your pocket. `.mixWithOthers` means it never interrupts
//  your music and nothing is audible. We also re-activate after interruptions /
//  route changes / media-services resets, which otherwise silently kill it.
//  (App-Store-disqualifying hack — fine here, this build never ships.)
//

import Foundation
import Combine
import AVFoundation

@MainActor
final class BackgroundAudio: ObservableObject {
    @Published private(set) var isActive = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var observersInstalled = false

    func start() {
        installObservers()
        activate()
    }

    func stop() {
        player.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        isActive = false
    }

    private func activate() {
        guard !isActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            let sr = session.sampleRate > 0 ? session.sampleRate : 44_100
            guard let format = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1) else { return }

            if !engine.attachedNodes.contains(player) {
                engine.attach(player)
            }
            engine.connect(player, to: engine.mainMixerNode, format: format)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { return }
            buffer.frameLength = buffer.frameCapacity
            if let ch = buffer.floatChannelData {
                let amp: Float = 1e-4               // inaudible, but non-zero
                for i in 0..<Int(buffer.frameLength) {
                    ch[0][i] = amp * sinf(Float(i) * 0.05)
                }
            }

            if !engine.isRunning { try engine.start() }
            player.scheduleBuffer(buffer, at: nil, options: .loops)
            player.play()
            isActive = true
        } catch {
            isActive = false
        }
    }

    /// Re-activate after the system tears the session down for any reason.
    private func reactivate() {
        isActive = false
        activate()
    }

    private func installObservers() {
        guard !observersInstalled else { return }
        observersInstalled = true
        let nc = NotificationCenter.default

        nc.addObserver(forName: AVAudioSession.interruptionNotification,
                       object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let ended = AVAudioSession.InterruptionType(rawValue: raw) == .ended
            Task { @MainActor in if ended { self?.reactivate() } }
        }
        nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in if self?.isActive == false { self?.activate() } }
        }
        nc.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reactivate() }
        }
    }
}
