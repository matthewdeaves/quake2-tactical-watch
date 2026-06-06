//
//  ContentView.swift
//  Quake2TacticalWatchComputer
//
//  Phone UI: a Sulaco/Quake-II "help-computer" terminal. The HUD tab is the
//  star — a glowing amber/green phosphor readout (vital signs, loadout, mission,
//  comms) framed in L-bracket targeting boxes. Pure screen: no chrome, no metal.
//  The Setup tab carries the plumbing/diagnostics.
//

import SwiftUI
import UIKit

struct ContentView: View {
    var body: some View {
        TabView {
            DebugHUDView()
                .tabItem { Label("HUD", systemImage: "gauge.with.dots.needle.bottom.50percent") }
            ConfigView()
                .tabItem { Label("Setup", systemImage: "antenna.radiowaves.left.and.right") }
        }
        .tint(Phosphor.amber)
    }
}

// MARK: - Config

private struct ConfigView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var listener: UDPListener
    @EnvironmentObject private var relay: WatchRelay
    @EnvironmentObject private var game: GameState
    @Environment(\.openURL) private var openURL
    @AppStorage(AppModel.forcePhoneAudioKey) private var forcePhoneAudio = false
    @AppStorage(WatchTransport.watchSoundKey) private var gameSounds = true
    @AppStorage(GameSounds.jumpKey) private var jumpSound = false
    @AppStorage(WatchTransport.watchHapticsKey) private var watchHaptics = false

    @State private var phoneIP: String = NetworkInfo.wifiIPv4() ?? "—"

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    Text("Auto-discovers your Quake machine (Quake 1 / 2 / 3) on the LAN — just play. (This phone: \(phoneIP):\(String(model.port)))")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Listener") {
                    Stepper("UDP port: \(String(model.port))",
                            value: Binding(get: { Int(model.port) },
                                           set: { model.port = UInt16(clamping: $0) }),
                            in: 1024...65535)
                    StatusRow(label: "Socket", value: listener.status.label,
                              ok: isListeningOK)
                    StatusRow(label: "Receiving", value: game.live ? "LIVE" : "idle",
                              ok: game.live)
                    HStack {
                        Button(model.isListening ? "Restart" : "Start") { model.startListening() }
                        Spacer()
                        if model.isListening {
                            Button("Stop", role: .destructive) { model.stopListening() }
                        }
                    }
                }

                Section("Watch") {
                    StatusRow(label: "Paired", value: relay.isPaired ? "yes" : "no", ok: relay.isPaired)
                    StatusRow(label: "App installed", value: relay.isWatchAppInstalled ? "yes" : "no",
                              ok: relay.isWatchAppInstalled)
                    StatusRow(label: "Reachable", value: relay.isReachable ? "yes" : "no",
                              ok: relay.isReachable)
                    LabeledContent("Context pushes", value: "\(relay.contextUpdates)")
                    LabeledContent("Events sent", value: "\(relay.eventsSent)")

                    Button {
                        relay.syncNow()
                    } label: {
                        Label("Sync to Watch", systemImage: "arrow.triangle.2.circlepath")
                    }
                    if !relay.lastSync.isEmpty {
                        Text(relay.lastSync)
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    if !relay.isWatchAppInstalled {
                        Button {
                            if let url = URL(string: "itms-watchs://") {
                                openURL(url)
                            }
                        } label: {
                            Label("Open Watch App to install", systemImage: "applewatch")
                        }
                        Text("iOS can't install the watch app itself — open Apple's **Watch** app, find **Tactical Computer**, tap **Install**. It auto-installs once provisioning includes this watch.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Feed") {
                    LabeledContent("Packets", value: "\(game.packetCount)")
                    LabeledContent("Map", value: game.meta?.level ?? "—")
                }

                Section("Audio") {
                    Toggle("Play audio on iPhone", isOn: $forcePhoneAudio)
                        .onChange(of: forcePhoneAudio) { _, _ in model.audioRoutingChanged() }
                    Toggle("Game sounds", isOn: $gameSounds)
                        .onChange(of: gameSounds) { _, _ in model.audioRoutingChanged() }
                    Toggle("Jump grunt", isOn: $jumpSound)
                        .onChange(of: jumpSound) { _, _ in model.audioRoutingChanged() }
                    Text(forcePhoneAudio
                         ? "The iPhone plays the game sounds and the watch stays silent — handy for screen-recording a demo. Turn it off to hand audio back to the watch. Sound only ever plays on one device."
                         : "The watch plays game sounds while it's connected; the iPhone takes over only when the watch isn't. Turn \u{201C}Play audio on iPhone\u{201D} on to force the sound out of the iPhone (e.g. for screen recording). Sound only ever plays on one device. \u{201C}Game sounds\u{201D} and \u{201C}Jump grunt\u{201D} apply wherever it's playing; the help-computer \u{201C}objectives updated\u{201D} voice always plays.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Watch") {
                    Toggle("Wrist haptics", isOn: $watchHaptics)
                        .onChange(of: watchHaptics) { _, _ in model.audioRoutingChanged() }
                    Text("These settings control the watch from here, to keep the wrist uncluttered. Volume is set on the watch itself. watchOS haptics carry a faint tone — for buzz with no sound, put the watch in Silent Mode.")
                        .font(.footnote).foregroundStyle(.secondary)
                }

                Section("Build") {
                    LabeledContent("Phone app", value: AppVersion.string)
                    LabeledContent("Watch app",
                                   value: relay.watchVersion.isEmpty ? "—" : relay.watchVersion)
                }
            }
            .scrollContentBackground(.hidden)
            .background(TerminalBackground())
            .navigationTitle("TACTICAL COMPUTER")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var isListeningOK: Bool {
        if case .listening = listener.status { return true }
        return false
    }
}

private struct StatusRow: View {
    let label: String
    let value: String
    let ok: Bool
    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 6) {
                Circle().fill(ok ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text(value).font(.system(.body, design: .monospaced)).foregroundStyle(ok ? .primary : .secondary)
            }
        }
    }
}

// MARK: - HUD (the marine help-computer; mirrors the watch)

private struct DebugHUDView: View {
    @EnvironmentObject private var game: GameState
    @EnvironmentObject private var relay: WatchRelay
    /// Bumped on every orientation flip → drives the CRT re-sync wobble + a glitch.
    @State private var reorient = 0

    /// Best available level name: the F1 location if we have it, else the map.
    private var sector: String {
        if let loc = game.objectives?.loc, !loc.isEmpty { return loc }
        return game.meta?.level ?? (game.live ? "STANDBY" : "—")
    }

    var body: some View {
        GeometryReader { geo in
            // Landscape when the page is wider than it is tall.
            let landscape = geo.size.width > geo.size.height
            ZStack {
                // Glass bleeds to every edge (incl. behind the Dynamic Island /
                // home indicator); the readouts stay in the safe area so no text
                // slips under the bars.
                TerminalBackground()
                VStack(spacing: 0) {
                    TerminalHeader(sector: sector, live: game.live)
                    layout(landscape: landscape)
                }
                // Only the readouts wobble/re-sync; the background glass stays put.
                .screenWobble(reorient)
                .animation(.spring(response: 0.5, dampingFraction: 0.55), value: landscape)
            }
            .onChange(of: landscape) { _, _ in reorient += 1 }
        }
        // A reorient kicks the horizontal-tear glitch, so the switch reads as a
        // real re-sync.
        .crtGlitch(trigger: game.hitCount + reorient, severity: game.healthSeverity)
        // Light blood splatter on each hit, fading over a few seconds (under the
        // death crack/skull layers).
        .overlay(BloodSplat(trigger: game.hitCount).ignoresSafeArea())
        // Death holds: shattered glass stays until a new game starts. Crack sits
        // under the skulls.
        .overlay(CrackOverlay(seed: game.deathCount, visible: game.dead).ignoresSafeArea())
        // Persistent low-health alarm: pulses amber→red, slow→fast as HP falls.
        .overlay(LowHealthSkull(severity: game.healthSeverity))
        .overlay(DeadSkull(dead: game.dead))
        // Punchy 3× flash on death AND on critical-HP crossings.
        .overlay(DeathFlash(trigger: game.deathCount + game.criticalCount).ignoresSafeArea())
        // CRT chrome on TOP of the (scrolling) content: scanlines, refresh sweep,
        // flicker, interference, and a tube vignette — worse as HP falls. Composited
        // as an overlay (not a layerEffect) because layerEffect can't rasterise the
        // HUD's ScrollViews — it would blank the readouts.
        .crtScreen(severity: game.healthSeverity)
        .preferredColorScheme(.dark)
        // Keep the phone awake while the marine is watching the HUD — a soldier
        // doesn't want the tac-computer blanking mid-firefight. Released when the
        // HUD leaves the screen (and iOS clears it automatically on background).
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Adaptive layout

    /// Portrait: one scrolling column. Landscape: vitals/loadout rail on the left,
    /// mission + comms on the right — both columns independently scrollable so
    /// nothing clips on the short landscape height.
    @ViewBuilder private func layout(landscape: Bool) -> some View {
        if let v = game.vitals, game.live {
            if landscape {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            vitalSignsBox(v)
                            gaugesRow(v)
                            weaponBox(v)
                            if v.pu.isActive { powerup(v.pu) }
                            if !game.inventory.isEmpty { inventoryBox(game.inventory) }
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            if let o = game.objectives, !o.isEmpty { mission(o) }
                            comms
                        }
                        .padding(12)
                    }
                    .frame(maxWidth: .infinity)
                }
                .transition(.opacity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        vitalSignsBox(v)
                        gaugesRow(v)
                        weaponBox(v)
                        if v.pu.isActive { powerup(v.pu) }
                        if !game.inventory.isEmpty { inventoryBox(game.inventory) }
                        if let o = game.objectives, !o.isEmpty { mission(o) }
                        comms
                    }
                    .padding(14)
                }
                .transition(.opacity)
            }
        } else {
            ScrollView { standby.padding(14) }
        }
    }

    // MARK: Vital signs

    private func vitalSignsBox(_ v: Vitals) -> some View {
        let c = Phosphor.vital(v.hp)
        return ReadoutBox(title: "VITAL SIGNS", tint: c) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(v.hp)")
                        .font(.system(size: 78, weight: .heavy, design: .monospaced))
                        .foregroundStyle(c)
                        .phosphorGlow(c, radius: 11, intensity: 0.7)
                        .contentTransition(.numericText())
                        .criticalFlicker(game.healthSeverity)
                    Text("HP")
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .foregroundStyle(c.opacity(0.65))
                    Spacer()
                    if relay.heartRate > 0 {
                        VStack(alignment: .trailing, spacing: 0) {
                            // Big ♥ that beats in time with the live heart rate
                            // (matches the watch HUD).
                            HeartBeat(bpm: relay.heartRate, glyphSize: 50)
                            Text("BPM")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Phosphor.amberDim)
                        }
                    }
                }
                SegBar(value: v.hp, maxValue: 100, color: c)
            }
        }
    }

    private func gaugesRow(_ v: Vitals) -> some View {
        // A Grid row sizes both cells to the taller one (ARMOR carries a bar), so
        // the ARMOR and AMMO boxes align top AND bottom in either orientation —
        // the gauges fill the row height, brackets included.
        Grid(horizontalSpacing: 12) {
            GridRow {
                gauge("ARMOR", v.armor, 200, Phosphor.green, bar: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                gauge("AMMO", v.ammo, 0, Phosphor.cyan, bar: false)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func weaponBox(_ v: Vitals) -> some View {
        ReadoutBox(title: "WEAPON", tint: Phosphor.amberDim) {
            Text(v.sel.isEmpty ? "—" : v.sel.uppercased())
                .font(.system(.title3, design: .monospaced).weight(.heavy))
                .tracking(1)
                .foregroundStyle(Phosphor.pale)
                .phosphorGlow(Phosphor.pale, radius: 4, intensity: 0.4)
                .lineLimit(1).minimumScaleFactor(0.5)
        }
    }

    private func gauge(_ label: String, _ value: Int, _ maxValue: Int,
                       _ color: Color, bar: Bool) -> some View {
        ReadoutBox(title: label, tint: color, bracket: 9) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(value)")
                    .font(.system(size: 42, weight: .heavy, design: .monospaced))
                    .foregroundStyle(color)
                    .phosphorGlow(color, radius: 6)
                    .contentTransition(.numericText())
                    .lineLimit(1).minimumScaleFactor(0.5)
                if bar { SegBar(value: value, maxValue: maxValue, color: color, segments: 12) }
            }
            // Fill the box so AMMO (no bar) stretches to ARMOR's height, number
            // pinned top-left.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func powerup(_ pu: Vitals.Powerup) -> some View {
        ReadoutBox(title: "POWERUP", tint: Phosphor.hazard) {
            HStack {
                Text(pu.label)
                    .font(.system(.headline, design: .monospaced).weight(.heavy)).tracking(1)
                Spacer()
                Text("\(pu.sec)s")
                    .font(.system(.title3, design: .monospaced).weight(.heavy))
            }
            .foregroundStyle(Phosphor.hazard)
            .phosphorGlow(Phosphor.hazard, radius: 5)
        }
        .background(HazardStripes())
    }

    // MARK: Inventory (Quake II pack — powerups, keys, ammo, arsenal)

    private func inventoryBox(_ items: [InventoryItem]) -> some View {
        // Render order + colour per class. Each non-empty class gets one row.
        let groups: [(label: String, color: Color, cat: InventoryItem.Category)] = [
            ("POWERUPS", Phosphor.hazard, .powerup),
            ("KEYS",     Phosphor.cyan,   .key),
            ("AMMO",     Phosphor.green,  .ammo),
            ("ARSENAL",  Phosphor.pale,   .weapon),
            ("MISC",     Phosphor.amber,  .other),
        ]
        return ReadoutBox(title: "INVENTORY", tint: Phosphor.cyan) {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(groups, id: \.label) { g in
                    let line = items.filter { $0.category == g.cat }
                    if !line.isEmpty { invRow(g.label, g.color, line) }
                }
            }
        }
    }

    private func invRow(_ label: String, _ color: Color, _ items: [InventoryItem]) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(label)
                .font(.system(.caption2, design: .monospaced).weight(.bold)).tracking(1)
                .foregroundStyle(Phosphor.amberDim)
                .frame(width: 72, alignment: .leading)
                .padding(.top, 2)
            // Joined into one wrapping line — reads like a terminal readout and
            // avoids a custom flow layout. Ammo shows its amount; everything else
            // shows ×N only when more than one is held.
            Text(items.map(invLabel).joined(separator: "   "))
                .font(.system(.footnote, design: .monospaced).weight(.medium))
                .foregroundStyle(color)
                .phosphorGlow(color, radius: 3, intensity: 0.4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func invLabel(_ it: InventoryItem) -> String {
        let n = it.name.uppercased()
        if it.category == .ammo { return "\(n) \(it.count)" }
        return it.count > 1 ? "\(n) ×\(it.count)" : n
    }

    // MARK: Mission

    private func mission(_ o: Objectives) -> some View {
        ReadoutBox(title: "MISSION", tint: Phosphor.green) {
            VStack(alignment: .leading, spacing: 11) {
                if !o.obj1.isEmpty { objectiveRow("01", o.obj1) }
                if !o.obj2.isEmpty { objectiveRow("02", o.obj2) }
                // Progress: counts first, SKILL/difficulty as the last item.
                if !o.kills.isEmpty || !o.goals.isEmpty || !o.secrets.isEmpty || !o.skill.isEmpty {
                    HStack(spacing: 8) {
                        if !o.kills.isEmpty { miniStat("KILLS", o.kills) }
                        if !o.goals.isEmpty { miniStat("GOALS", o.goals) }
                        if !o.secrets.isEmpty { miniStat("SECRETS", o.secrets) }
                        if !o.skill.isEmpty { miniStat("SKILL", o.skill.uppercased()) }
                    }
                }
            }
        }
    }

    private func objectiveRow(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(n)
                .font(.system(.caption, design: .monospaced).weight(.heavy))
                .foregroundStyle(Phosphor.background)
                .frame(width: 24, height: 20)
                .background(Phosphor.green, in: RoundedRectangle(cornerRadius: 3))
                .phosphorGlow(Phosphor.green, radius: 4)
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(Phosphor.amber)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title3, design: .monospaced).weight(.heavy))
                .foregroundStyle(Phosphor.amber)
                .phosphorGlow(Phosphor.amber, radius: 3, intensity: 0.45)
                .lineLimit(1).minimumScaleFactor(0.5)
            Text(label)
                .font(.system(.caption2, design: .monospaced)).tracking(1)
                .foregroundStyle(Phosphor.amberDim)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .overlay(CornerBrackets(length: 7).stroke(Phosphor.amberDim.opacity(0.6), lineWidth: 1))
    }

    // MARK: Comms

    private var comms: some View {
        // Only meaningful messages (pickups / story). Damage is conveyed by the
        // red flash, not logged as spam.
        let msgs = game.events.filter { $0.isCenterprint && !($0.msg ?? "").isEmpty }
        return ReadoutBox(title: "COMMS", tint: Phosphor.amberDim) {
            VStack(alignment: .leading, spacing: 6) {
                if msgs.isEmpty {
                    HStack(spacing: 6) {
                        Text("AWAITING TRANSMISSION")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(Phosphor.amberDim)
                        CursorBlock(color: Phosphor.green, height: 12)
                    }
                } else {
                    ForEach(Array(msgs.suffix(12).reversed().enumerated()), id: \.element.id) { idx, e in
                        HStack(alignment: .top, spacing: 7) {
                            Text(idx == 0 ? "▸" : "·")
                                .foregroundStyle(idx == 0 ? Phosphor.green : Phosphor.amberDim)
                            Text(e.msg ?? "")
                                .foregroundStyle(idx == 0 ? Phosphor.amber : Phosphor.amberDim)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.system(.footnote, design: .monospaced))
                    }
                }
            }
        }
    }

    // MARK: Standby / no-signal terminal

    private var standby: some View {
        // `lost` = we had a feed and it dropped (red SIGNAL LOST) vs never had one
        // yet (amber SYSTEM OFFLINE). Either way: a full marine-terminal boot log.
        let lost = game.vitals != nil
        let accent = lost ? Phosphor.danger : Phosphor.amber
        return VStack(alignment: .leading, spacing: 16) {
            // Masthead
            VStack(alignment: .leading, spacing: 2) {
                Text("MARINE TACTICAL COMPUTER")
                    .font(.system(.headline, design: .monospaced).weight(.heavy))
                    .foregroundStyle(Phosphor.amber)
                    .phosphorGlow(Phosphor.amber, radius: 6)
                Text("OPERATION ALIEN OVERLORD · STROGGOS  \(AppVersion.string)")
                    .font(.system(.caption2, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(Phosphor.amberDim)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            Rectangle().fill(Phosphor.line).frame(height: 1)

            // Power-on self test — the "system coming up" feel.
            VStack(alignment: .leading, spacing: 4) {
                bootLine("> BOOT ROM ............... OK")
                bootLine("> COMBAT ARMOR LINK ...... OK")
                bootLine("> BIO-MONITOR ............ OK")
                bootLine("> THREAT SCANNER ......... OK")
                bootLine("> SLIPGATE TELEMETRY ..... OK")
                bootLine("> SCANNING LAN · UDP 27999")
                bootLine(lost ? "> CARRIER LOST" : "> AWAITING CARRIER ........",
                         color: lost ? Phosphor.danger : Phosphor.green.opacity(0.7))
            }

            // Big status word + blinking block.
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(lost ? "SIGNAL LOST" : "SYSTEM OFFLINE")
                    .font(.system(size: 36, weight: .heavy, design: .monospaced))
                    .foregroundStyle(accent)
                    .phosphorGlow(accent, radius: 9)
                    .lineLimit(1).minimumScaleFactor(0.55)
                CursorBlock(color: accent, height: 28)
            }

            Text(lost ? "// UPLINK DROPPED — IS THE GAME STILL RUNNING?"
                      : "// START A GAME ON THE QUAKE MACHINE TO ESTABLISH THE LINK")
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Phosphor.green.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            // Live prompt — the terminal is awake and waiting.
            HStack(spacing: 6) {
                Text(">")
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundStyle(Phosphor.green)
                    .phosphorGlow(Phosphor.green, radius: 4)
                CursorBlock(color: Phosphor.green, height: 16)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .topLeading)
    }

    private func bootLine(_ s: String, color: Color = Phosphor.green.opacity(0.7)) -> some View {
        Text(s)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(color)
    }
}

/// Full-screen digital skull that flashes 3× on death / when health goes critical.
private struct DeathFlash: View {
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
            .shadow(color: Phosphor.danger.opacity(0.8), radius: 20)
            .padding(40)
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

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
