//
//  KeepAwake.swift
//  TacticalComputerWatchApp Watch App
//
//  Keeps the tactical computer awake, frontmost, and interactive for the whole
//  match — and records the match as a workout you can control like any real
//  Health app (start / pause / resume / end-and-save).
//
//  watchOS gives a normal app no way to stay on-screen; the ONLY API that keeps
//  an app at the front of the stack (so it reappears on wrist-raise instead of
//  the clock), holds the Always-On display, and stays interactive is an
//  HKWorkoutSession. So the "keep awake" mechanism IS a workout: an "Other"
//  workout runs while you play, collecting heart rate + active energy via a live
//  builder; ending it saves the session to Health (HR, calories, duration).
//  Pausing keeps the app frontmost (session still active) but stops accruing.
//

import Foundation
import HealthKit
import WatchConnectivity

@Observable
@MainActor
final class WorkoutKeepAlive: NSObject {

    enum Phase { case idle, running, paused }

    private(set) var phase: Phase = .idle
    /// Live heart rate in BPM (0 until the first sample). Shown on the HUD.
    private(set) var heartRate: Int = 0
    /// Active energy burned this session, kcal.
    private(set) var activeCalories: Int = 0

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var ending = false   // teardown in progress; blocks a racing start()

    /// Workout elapsed time, pause-aware (read live by the UI each tick).
    var elapsed: TimeInterval { builder?.elapsedTime ?? 0 }

    // MARK: Controls

    /// Begin a session. Safe to call repeatedly; no-op once running/paused or
    /// while a previous session is still tearing down.
    func start() {
        guard HKHealthStore.isHealthDataAvailable(), phase == .idle, !ending else { return }
        phase = .running   // optimistic; delegate keeps it in sync
        Task { await begin() }
    }

    func pause()  { guard phase == .running else { return }; session?.pause() }
    func resume() { guard phase == .paused else { return }; session?.resume() }

    /// End the workout and SAVE it to Health (the logged Quake session).
    func end() {
        guard phase != .idle, !ending else { return }
        ending = true
        phase = .idle              // close the controls window synchronously
        Task { await finishAndSave() }
    }

    // MARK: Session plumbing

    private func begin() async {
        // Defensively clear any leftover session so we never double-arm.
        session?.end()
        session = nil
        builder = nil
        let share: Set = [HKQuantityType.workoutType(),
                          HKQuantityType(.activeEnergyBurned),
                          HKQuantityType(.heartRate)]
        let read: Set<HKObjectType> = [HKQuantityType(.heartRate),
                                       HKQuantityType(.activeEnergyBurned)]
        try? await store.requestAuthorization(toShare: share, read: read)

        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .indoor

        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store,
                                                   workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s
            builder = b

            let begin = Date()
            s.startActivity(with: begin)
            try await b.beginCollection(at: begin)
            // Brand the saved workout so it reads as "Quake II" in Health/Fitness.
            try? await b.addMetadata([HKMetadataKeyWorkoutBrandName: "Quake II"])
        } catch {
            phase = .idle
            session = nil
            builder = nil
        }
    }

    private func finishAndSave() async {
        defer { teardown() }
        guard let s = session, let b = builder else { return }
        let finish = Date()
        s.stopActivity(with: finish)
        try? await b.endCollection(at: finish)
        try? await b.finishWorkout()   // saves the Quake session to Health
        s.end()
    }

    /// Single place that clears session state, so a delegate-driven end and an
    /// app-driven end can't leave stale objects or a half-reset HUD.
    private func teardown() {
        session = nil
        builder = nil
        phase = .idle
        ending = false
        heartRate = 0
        activeCalories = 0
    }
}

// Delegate callbacks arrive off the main actor; hop back to touch state.
extension WorkoutKeepAlive: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState,
                                    date: Date) {
        Task { @MainActor in
            switch toState {
            case .running:            self.phase = .running
            case .paused:             self.phase = .paused
            case .ended, .stopped:
                // If the session ended outside our own end() (system, error),
                // clear everything so we don't leak or double-arm on restart.
                if !self.ending { self.teardown() }
            default:                  break
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didFailWithError error: Error) {
        Task { @MainActor in if !self.ending { self.teardown() } }
    }

    // A pause/resume from the SYSTEM controls (the watchOS Smart Stack live-workout
    // widget, Control Center, side-button) is delivered as a workout EVENT, which
    // doesn't always come through `didChangeTo`. Handle it here so the wrist pill's
    // pause/resume actually drives our session + UI. Apple recommends catching
    // both the state change AND the event.
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession,
                                    didGenerate event: HKWorkoutEvent) {
        Task { @MainActor in
            switch event.type {
            case .pause:  self.phase = .paused
            case .resume: self.phase = .running
            default:      break
            }
        }
    }
}

extension WorkoutKeepAlive: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                                    didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        let kcalType = HKQuantityType(.activeEnergyBurned)

        var hr: Int?
        var kcal: Int?
        if collectedTypes.contains(hrType),
           let q = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity() {
            hr = Int(q.doubleValue(for: .count().unitDivided(by: .minute())).rounded())
        }
        if collectedTypes.contains(kcalType),
           let q = workoutBuilder.statistics(for: kcalType)?.sumQuantity() {
            kcal = Int(q.doubleValue(for: .kilocalorie()).rounded())
        }
        Task { @MainActor in
            if let hr {
                self.heartRate = hr
                self.sendHeartRate(hr)   // mirror to the phone HUD
            }
            if let kcal { self.activeCalories = kcal }
        }
    }
}

extension WorkoutKeepAlive {
    /// Push the live BPM to the phone. Use sendMessage when reachable (low
    /// latency, not coalesced) and fall back to app-context so the latest value
    /// still lands when the phone app is backgrounded.
    func sendHeartRate(_ bpm: Int) {
        guard WCSession.isSupported() else { return }
        let s = WCSession.default
        guard s.activationState == .activated else { return }
        if s.isReachable {
            s.sendMessage(["hr": bpm], replyHandler: nil, errorHandler: nil)
        } else {
            try? s.updateApplicationContext(["hr": bpm])
        }
    }
}
