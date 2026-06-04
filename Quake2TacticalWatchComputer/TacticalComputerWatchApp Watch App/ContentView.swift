//
//  ContentView.swift
//  TacticalComputerWatchApp Watch App
//
//  The tactical computer on the wrist: a paged phosphor terminal — Vitals /
//  Status / Comms / Workout / Settings — styled like the Quake II help-computer
//  crossed with the Aliens (1986) Sulaco screens. Glowing amber/green readouts
//  in L-bracket targeting frames. Pure screen: no chrome, no metal.
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var conn: WatchConnector

    var body: some View {
        TabView {
            VitalsView()
            // STATUS carries the objectives computer + pack — Quake II only.
            // On Quake 1 it would be just the sector name, so we drop the page
            // entirely (the sector folds into COMMS) — no sparse screens.
            if !conn.isQuake1 { StatusView() }
            CommsView()
            WorkoutControlView()
            SettingsView()
        }
        .tabViewStyle(.verticalPage)
        // The CRT is always alive on-screen (only the Always-On dimmed state
        // freezes it, which is the real battery case).
        .phosphorScreen()
        // Red damage flash across the whole computer.
        .overlay(
            Phosphor.danger
                .opacity(conn.damageFlash ? 0.35 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.2), value: conn.damageFlash)
        )
        // CRT warp: random + on tap + on every hit, worsening as HP drops.
        .crtGlitch(trigger: conn.hitCount, severity: conn.healthSeverity)
        // Light blood splatter on each hit, fading over a few seconds (under the
        // death crack/skull layers).
        .overlay(BloodSplat(trigger: conn.hitCount).ignoresSafeArea())
        // Death holds: shattered glass stays + a permanent red skull, until a new
        // game starts. Crack sits under the skulls.
        .overlay(CrackOverlay(seed: conn.deathCount, visible: conn.dead).ignoresSafeArea())
        // Persistent low-health alarm: pulses amber→red, slow→fast as HP falls.
        .overlay(LowHealthSkull(severity: conn.healthSeverity))
        .overlay(DeadSkull(dead: conn.dead))
        // Punchy 3× flash on death AND on critical-HP crossings.
        .overlay(DeathFlash(trigger: conn.deathCount + conn.criticalCount).ignoresSafeArea())
    }
}

/// Full-screen "☠" that flashes 3× (0.5s on / 0.5s off) on death.
struct DeathFlash: View {
    let trigger: Int
    @State private var visible = false
    @State private var flashTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if visible {
                Phosphor.background.opacity(0.9).ignoresSafeArea()
                skull
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, newValue in
            guard newValue > 0 else { return }
            flashTask?.cancel()
            flashTask = Task { await flash() }
        }
    }

    private var skull: some View {
        Image("skull")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundStyle(Phosphor.danger)
            .shadow(color: Phosphor.danger.opacity(0.8), radius: 10)
            .padding(10)
    }

    @MainActor private func flash() async {
        defer { withAnimation(.easeOut(duration: 0.06)) { visible = false } }
        for _ in 0..<3 {
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.06)) { visible = true }
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.easeOut(duration: 0.06)) { visible = false }
            try? await Task.sleep(for: .seconds(0.5))
        }
    }
}

// MARK: - Vitals

struct VitalsView: View {
    @EnvironmentObject private var conn: WatchConnector
    @Environment(WorkoutKeepAlive.self) private var workout

    var body: some View {
        // The primary screen. Fitted to ONE screen (no ScrollView) so the page
        // indicator stays normal-sized: HP + live heart rate up top, ARMOR/AMMO
        // as big bracketed counters, the active powerup tucked in if there's one.
        VStack(spacing: 6) {
            if let v = conn.vitals, conn.live {
                let c = Phosphor.vital(v.hp)

                // HP — the hero number — with the live heartbeat alongside.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(v.hp)")
                        .font(.system(size: 48, weight: .heavy, design: .monospaced))
                        .foregroundStyle(c)
                        .phosphorGlow(c, radius: 8, intensity: 0.75)
                        .contentTransition(.numericText())
                        .criticalFlicker(conn.healthSeverity)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Text("HP")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(c.opacity(0.7))
                    Spacer(minLength: 0)
                    if workout.heartRate > 0 {
                        HeartBeat(bpm: workout.heartRate)
                    }
                }
                SegmentGauge(label: "HEALTH", value: v.hp, maxValue: 100, color: c)

                // ARMOR + AMMO — big counters, each in its own targeting frame.
                HStack(spacing: 6) {
                    counter("ARMOR", v.armor, Phosphor.green)
                    counter("AMMO", v.ammo, Phosphor.cyan)
                }

                // WEAPON — one compact line beneath the counters.
                HStack(spacing: 5) {
                    Text("WPN")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Phosphor.amberDim)
                    Text(v.sel.isEmpty ? "—" : v.sel.uppercased())
                        .font(.system(.footnote, design: .monospaced).weight(.bold))
                        .foregroundStyle(Phosphor.pale)
                        .phosphorGlow(Phosphor.pale, radius: 3, intensity: 0.4)
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Spacer(minLength: 0)
                }

                // Powerup countdown (Quake II) — only when one is running, so the
                // screen stays tight when there isn't.
                if v.pu.isActive {
                    PowerupBadge(label: v.pu.label, seconds: v.pu.sec)
                }

                Spacer(minLength: 0)
            } else {
                WaitingView(signalLost: conn.vitals != nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 4)
        .navigationTitle("VITALS")
    }

    /// A big bracket-framed numeric counter (ARMOR / AMMO) for the vitals screen.
    private func counter(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Phosphor.amberDim)
            Text("\(value)")
                .font(.system(size: 32, weight: .heavy, design: .monospaced))
                .foregroundStyle(color)
                .phosphorGlow(color, radius: 5)
                .contentTransition(.numericText())
                .lineLimit(1).minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .overlay(CornerBrackets(length: 7).stroke(Phosphor.amberDim.opacity(0.55), lineWidth: 1))
    }
}

/// A ♥ that pulses in time with the player's real heart rate, BPM beside it.
private struct HeartBeat: View {
    let bpm: Int
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        if dimmed {
            readout(scale: 1.0)        // Always-On: static, no animation
        } else {
            let period = bpm > 0 ? 60.0 / Double(bpm) : 1.0
            TimelineView(.animation) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                let phase = t.truncatingRemainder(dividingBy: period) / period
                let beat = pow(max(0.0, sin(phase * .pi * 2)), 8)   // sharp spike/beat
                readout(scale: 1.0 + 0.35 * beat)
            }
        }
    }

    private func readout(scale: Double) -> some View {
        HStack(spacing: 3) {
            Text("♥")
                .font(.system(size: 40, weight: .heavy, design: .monospaced))
                .foregroundStyle(Phosphor.danger)
                .phosphorGlow(Phosphor.danger, radius: 6)
                .scaleEffect(scale)
            Text("\(bpm)")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundStyle(Phosphor.amberDim)
        }
        .lineLimit(1).minimumScaleFactor(0.5)
    }
}

private struct PowerupBadge: View {
    let label: String
    let seconds: Int
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(seconds)s")
        }
        .font(.system(.caption, design: .monospaced).weight(.heavy))
        .foregroundStyle(Phosphor.hazard)
        .phosphorGlow(Phosphor.hazard, radius: 4)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(HazardStripes())
        .overlay(CornerBrackets(length: 6).stroke(Phosphor.hazard, lineWidth: 1))
    }
}

// MARK: - Status (sector / objective context)

struct StatusView: View {
    @EnvironmentObject private var conn: WatchConnector

    /// Best available level name: the F1 location if we have it, else the map.
    private var sector: String {
        if let loc = conn.objectives?.loc, !loc.isEmpty { return loc }
        return conn.meta?.level ?? "—"
    }

    var body: some View {
        Group {
            // On signal loss, clear ALL mission data (matches the iPhone) — show
            // the standby/lost terminal instead of a stale sector/objectives.
            if conn.live {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        TerminalPanel(title: "SECTOR", tint: Phosphor.green) {
                            Text(sector.uppercased())
                                .font(.system(.headline, design: .monospaced))
                                .foregroundStyle(Phosphor.green)
                                .phosphorGlow(Phosphor.green, radius: 4)
                                .lineLimit(2).minimumScaleFactor(0.6)
                        }

                        if let o = conn.objectives, !o.isEmpty {
                            if !o.obj1.isEmpty || !o.obj2.isEmpty {
                                TerminalPanel(title: "OBJECTIVES") {
                                    VStack(alignment: .leading, spacing: 5) {
                                        if !o.obj1.isEmpty { objective("1", o.obj1) }
                                        if !o.obj2.isEmpty { objective("2", o.obj2) }
                                    }
                                    // The "1" badge is tall — nudge it down so it
                                    // clears the burned-in panel title.
                                    .padding(.top, 4)
                                }
                            }
                            // Progress: counts first, with SKILL as the last row.
                            if hasProgress(o) {
                                TerminalPanel(title: "PROGRESS") {
                                    VStack(alignment: .leading, spacing: 3) {
                                        if !o.kills.isEmpty { row("KILLS", o.kills) }
                                        if !o.goals.isEmpty { row("GOALS", o.goals) }
                                        if !o.secrets.isEmpty { row("SECRETS", o.secrets) }
                                        if !o.skill.isEmpty { row("SKILL", o.skill.uppercased()) }
                                    }
                                }
                            }
                        }

                        // The carried pack (Quake II only). Absent on Quake 1, so
                        // the panel simply doesn't appear — no dead space.
                        if !conn.inventory.isEmpty {
                            TerminalPanel(title: "PACK", tint: Phosphor.cyan) {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(packGroups(conn.inventory), id: \.label) { g in
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(g.label)
                                                .font(.system(.caption2, design: .monospaced).weight(.bold))
                                                .tracking(1)
                                                .foregroundStyle(Phosphor.amberDim)
                                            Text(g.items.map(invLabel).joined(separator: "  "))
                                                .font(.system(.footnote, design: .monospaced))
                                                .foregroundStyle(g.color)
                                                .phosphorGlow(g.color, radius: 2, intensity: 0.4)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                }
                            }
                        }

                        // Frags are deathmatch-only (always 0 in single-player), so
                        // we only surface them when there's a score / spectating.
                        if let v = conn.vitals, v.frags > 0 || v.spec != 0 {
                            TerminalPanel(title: "COMBAT", tint: Phosphor.danger) {
                                VStack(alignment: .leading, spacing: 3) {
                                    if v.frags > 0 { row("FRAGS", "\(v.frags)") }
                                    if v.spec != 0 { row("MODE", "SPECTATOR") }
                                }
                            }
                        }

                        if conn.objectives == nil && conn.meta == nil {
                            HStack(spacing: 5) {
                                Text("AWAITING MISSION DATA")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(Phosphor.amberDim)
                                CursorBlock(color: Phosphor.green, height: 11)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                }
            } else {
                WaitingView(signalLost: conn.vitals != nil)
                    .padding(.horizontal, 4)
            }
        }
        .navigationTitle("STATUS")
    }

    private func hasProgress(_ o: Objectives) -> Bool {
        !o.kills.isEmpty || !o.goals.isEmpty || !o.secrets.isEmpty || !o.skill.isEmpty
    }

    private func objective(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(n)
                .foregroundStyle(Phosphor.background)
                .frame(width: 16, height: 16)
                .background(Phosphor.green, in: RoundedRectangle(cornerRadius: 3))
                .phosphorGlow(Phosphor.green, radius: 3)
            Text(text)
                .foregroundStyle(Phosphor.amber)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(.footnote, design: .monospaced).weight(.semibold))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).foregroundStyle(Phosphor.amberDim)
            Spacer()
            Text(v)
                .font(.system(.footnote, design: .monospaced).weight(.bold))
                .foregroundStyle(Phosphor.green)
                .phosphorGlow(Phosphor.green, radius: 2, intensity: 0.4)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .font(.system(.footnote, design: .monospaced))
    }

    // MARK: PACK (Quake II carried inventory, grouped + colour-coded)

    private func packGroups(_ items: [InventoryItem])
        -> [(label: String, color: Color, items: [InventoryItem])] {
        let order: [(String, Color, InventoryItem.Category)] = [
            ("POWERUPS", Phosphor.hazard, .powerup),
            ("KEYS",     Phosphor.cyan,   .key),
            ("AMMO",     Phosphor.green,  .ammo),
            ("ARSENAL",  Phosphor.pale,   .weapon),
            ("MISC",     Phosphor.amber,  .other),
        ]
        return order.compactMap { o in
            let f = items.filter { $0.category == o.2 }
            return f.isEmpty ? nil : (label: o.0, color: o.1, items: f)
        }
    }

    private func invLabel(_ it: InventoryItem) -> String {
        let n = it.name.uppercased()
        if it.category == .ammo { return "\(n) \(it.count)" }
        return it.count > 1 ? "\(n) ×\(it.count)" : n
    }
}

// MARK: - Comms (story / pickup messages — the in-fiction help-computer feed)

struct CommsView: View {
    @EnvironmentObject private var conn: WatchConnector

    var body: some View {
        Group {
            if conn.live {
                // Fitted to one screen: newest on top, capped to what fits, so the
                // page indicator stays the normal size (no internal scroll).
                VStack(alignment: .leading, spacing: 8) {
                // Quake 1 has no STATUS page — surface the sector here so the
                // level name is never lost.
                if conn.isQuake1 {
                    TerminalPanel(title: "SECTOR", tint: Phosphor.green) {
                        Text(conn.sector.uppercased())
                            .font(.system(.headline, design: .monospaced))
                            .foregroundStyle(Phosphor.green)
                            .phosphorGlow(Phosphor.green, radius: 4)
                            .lineLimit(2).minimumScaleFactor(0.6)
                    }
                }
                TerminalPanel(title: "COMMS LOG") {
                    VStack(alignment: .leading, spacing: 6) {
                        if conn.comms.isEmpty {
                            HStack(spacing: 5) {
                                Text("— no transmissions —")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(Phosphor.amberDim)
                                CursorBlock(color: Phosphor.green, height: 11)
                            }
                        } else {
                            ForEach(Array(conn.comms.suffix(6).reversed().enumerated()), id: \.element.id) { idx, e in
                                HStack(alignment: .top, spacing: 5) {
                                    Text(idx == 0 ? "▸" : "·")
                                        .foregroundStyle(idx == 0 ? Phosphor.green : Phosphor.amberDim)
                                    Text(e.msg ?? "")
                                        .foregroundStyle(idx == 0 ? Phosphor.amber : Phosphor.amberDim)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(2)
                                }
                                .font(.system(.footnote, design: .monospaced))
                            }
                        }
                    }
                }
                }
            } else {
                // Signal lost ⇒ clear the comms log too.
                WaitingView(signalLost: conn.vitals != nil)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 4)
        .navigationTitle("COMMS")
    }
}

// MARK: - Workout controls (start / pause / resume / end & save)

struct WorkoutControlView: View {
    @Environment(WorkoutKeepAlive.self) private var workout

    var body: some View {
        VStack(spacing: 6) {
            Spacer(minLength: 0)

            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(timeString(workout.elapsed))
                    .font(.system(size: 32, weight: .heavy, design: .monospaced))
                    .foregroundStyle(workout.phase == .paused ? Phosphor.amberDim : Phosphor.amber)
                    .phosphorGlow(workout.phase == .paused ? Phosphor.amberDim : Phosphor.amber, radius: 6)
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.6)
            }

            HStack(spacing: 16) {
                stat("♥ BPM", "\(workout.heartRate)", Phosphor.danger)
                stat("KCAL", "\(workout.activeCalories)", Phosphor.green)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .overlay(CornerBrackets(length: 7).stroke(Phosphor.amberDim.opacity(0.55), lineWidth: 1))

            statusLine

            Spacer(minLength: 0)

            controls
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 6)
        .navigationTitle("WORKOUT")
    }

    @ViewBuilder private var statusLine: some View {
        let info: (String, Color) = {
            switch workout.phase {
            case .running: return ("● RECORDING", Phosphor.green)
            case .paused:  return ("❚❚ PAUSED", Phosphor.amberDim)
            case .idle:    return ("○ STANDBY", Phosphor.amberDim)
            }
        }()
        Text(info.0)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .foregroundStyle(info.1)
    }

    @ViewBuilder private var controls: some View {
        switch workout.phase {
        case .running:
            HStack {
                Button { workout.pause() } label: {
                    Label("Pause", systemImage: "pause.fill")
                }.tint(Phosphor.amberDim)
                Button(role: .destructive) { workout.end() } label: {
                    Label("End", systemImage: "stop.fill")
                }
            }
            .font(.system(.footnote, design: .monospaced))
        case .paused:
            HStack {
                Button { workout.resume() } label: {
                    Label("Resume", systemImage: "play.fill")
                }.tint(Phosphor.green)
                Button(role: .destructive) { workout.end() } label: {
                    Label("End", systemImage: "stop.fill")
                }
            }
            .font(.system(.footnote, design: .monospaced))
        case .idle:
            Button { workout.start() } label: {
                Label("Start session", systemImage: "play.fill")
            }
            .tint(Phosphor.green)
            .font(.system(.footnote, design: .monospaced))
        }
    }

    private func stat(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(spacing: 2) {
            Text(k).font(.system(.caption2, design: .monospaced)).foregroundStyle(Phosphor.amberDim)
            Text(v).font(.system(.title3, design: .monospaced).weight(.bold))
                .foregroundStyle(c).phosphorGlow(c, radius: 3, intensity: 0.45)
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }
}

// MARK: - Settings (last page: audio + build)

struct SettingsView: View {
    // Volume is the ONLY audio control that stays on the watch. Game sounds,
    // jump SFX and wrist haptics moved to the iPhone app (Setup) to cut on-wrist
    // clutter; they arrive via the app context and are persisted by WatchConnector
    // into this device's UserDefaults, so GameSounds/Haptics read them unchanged.
    @AppStorage(GameSounds.volumeKey) private var volume = 1.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                TerminalPanel(title: "VOLUME") {
                    // −/+ buttons, not a slider: the Digital Crown is captured by
                    // the vertical page TabView, so a slider can't be turned. Big
                    // tap targets, 10% steps.
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("LEVEL")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Phosphor.amberDim)
                            Spacer()
                            Text("\(Int((volume * 100).rounded()))%")
                                .font(.system(.caption, design: .monospaced).weight(.bold))
                                .foregroundStyle(Phosphor.green)
                                .phosphorGlow(Phosphor.green, radius: 2, intensity: 0.4)
                        }
                        HStack(spacing: 8) {
                            Button { step(-0.1) } label: {
                                Image(systemName: "speaker.minus.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .tint(Phosphor.amberDim)
                            Button { step(0.1) } label: {
                                Image(systemName: "speaker.plus.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .tint(Phosphor.green)
                        }
                        .font(.system(.body, design: .monospaced))
                        VolumeBars(level: volume)
                        Text("Game sounds, jump SFX and haptics are set in the iPhone app (Setup).")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Phosphor.amberDim)
                            .padding(.top, 2)
                    }
                }

                TerminalPanel(title: "SYSTEM") {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TACTICAL COMPUTER")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Phosphor.amberDim)
                        Text(AppVersion.string)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Phosphor.amberDim.opacity(0.7))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 4)
        }
        .navigationTitle("SETTINGS")
    }

    /// Adjust volume in clean 10% steps, snapped and clamped to 0…1.
    private func step(_ delta: Double) {
        let next = ((volume + delta) * 10).rounded() / 10
        volume = min(1.0, max(0.0, next))
    }
}

/// A 10-cell level meter for the volume readout.
private struct VolumeBars: View {
    let level: Double
    private var filled: Int { Int((min(max(level, 0), 1) * 10).rounded()) }
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<10, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < filled ? Phosphor.green : Phosphor.green.opacity(0.15))
                    .frame(height: 7)
            }
        }
        .phosphorGlow(Phosphor.green, radius: 2, intensity: 0.4)
    }
}

// MARK: - Shared

private struct WaitingView: View {
    var signalLost = false
    var body: some View {
        let accent = signalLost ? Phosphor.danger : Phosphor.amber
        return VStack(alignment: .leading, spacing: 7) {
            Text("> TACTICAL UPLINK")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Phosphor.green.opacity(0.7))
            Text(signalLost ? "> CARRIER LOST" : "> AWAITING CARRIER")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Phosphor.green.opacity(0.7))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(signalLost ? "SIGNAL LOST" : "STANDBY")
                    .font(.system(.title3, design: .monospaced).weight(.heavy))
                    .foregroundStyle(accent)
                    .phosphorGlow(accent, radius: 6)
                    .lineLimit(1).minimumScaleFactor(0.6)
                CursorBlock(color: accent, height: 20)
            }
            Text(signalLost ? "no uplink — game stopped?" : "awaiting game data…")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Phosphor.amberDim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

#Preview {
    ContentView()
        .environmentObject(WatchConnector())
        .environment(WorkoutKeepAlive())
}
