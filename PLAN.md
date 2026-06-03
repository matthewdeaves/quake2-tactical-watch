# Quake II "Tactical Computer" — Apple Watch Companion App

**Plan v1 · 2026-06-03**

The old Mac runs Quake II (yquake2 5.11 PPC port). A tiny, cvar-gated patch in
the engine emits a live UDP feed of the player's in-game state and events. An
iPhone app receives that feed on the LAN and relays it to a watchOS app that
renders the player's in-fiction **computer** — health, armor, ammo, inventory,
mission objectives — on your wrist, with haptics on damage and sounds on events.

The thematic hook is exact: Quake II's **help computer** (the F1 screen) is
literally styled as a Strogg/marine terminal showing your mission objectives and
progress. The watch *becomes* that computer — always on, always on your wrist.

---

## 1. What the engine actually knows (deep code review)

All references below are real and verified against
`/Users/matt/Documents/old-mac-quake2/yquake2/src`.

### 1.1 Live player vitals — `player_state_t.stats[MAX_STATS]`

`short stats[32]` (`common/header/shared.h:1106`, `MAX_STATS=32` at `:978`).
Received every server frame in `cl.frame.playerstate.stats[]`
(`client/header/client.h`, `frame_t`). Indices (`shared.h:959–977`):

| Idx | Define | Meaning | Watch use |
|----|--------|---------|-----------|
| 0 | `STAT_HEALTH_ICON` | image index of health icon | pick icon glyph |
| 1 | `STAT_HEALTH` | current health (0–100+) | **big number / gauge** |
| 2 | `STAT_AMMO_ICON` | ammo icon image index | glyph |
| 3 | `STAT_AMMO` | ammo for selected weapon | **ammo readout** |
| 4 | `STAT_ARMOR_ICON` | armor / power-shield icon | glyph |
| 5 | `STAT_ARMOR` | armor points / shield cells | **armor gauge** |
| 6 | `STAT_SELECTED_ICON` | selected item icon | glyph |
| 7 | `STAT_PICKUP_ICON` | last pickup icon | pickup toast |
| 8 | `STAT_PICKUP_STRING` | `CS_ITEMS + idx` of pickup | **"You got the X"** |
| 9 | `STAT_TIMER_ICON` | powerup icon (quad/invuln/enviro/breather) | powerup badge |
| 10 | `STAT_TIMER` | powerup seconds remaining | **countdown ring** |
| 11 | `STAT_HELPICON` | help / current-weapon icon | glyph |
| 12 | `STAT_SELECTED_ITEM` | selected inventory index | resolve name via `CS_ITEMS` |
| 13 | `STAT_LAYOUTS` | bit0=scoreboard, bit1=inventory visible | mode switch |
| 14 | `STAT_FRAGS` | score / frags | **score** |
| 15 | `STAT_FLASHES` | bit0=health hit, bit1=armor hit, bit2=ammo (cleared each frame) | **damage haptic trigger** |
| 16 | `STAT_CHASE` | chase-cam target (`CS_PLAYERSKINS` idx) | spectator name |
| 17 | `STAT_SPECTATOR` | spectator flag | mode |

These are filled server-side once per frame in `G_SetStats()`
(`game/player/hud.c:397–575`); pickup string/icon set on touch in
`game/g_items.c:1175–1179` (3-second window); damage flashes in
`game/player/view.c:88–99`. **No engine change is needed to read them — they
already arrive on the client.**

### 1.2 Inventory — `cl.inventory[MAX_ITEMS]`

`int inventory[256]` (`client/header/client.h:163`). Filled from `svc_inventory`
in `CL_ParseInventory()` (`client/cl_inventory.c:29–38`) — a full 256-short
array. Non-zero slots are owned items; quantity is the value; **name** is
`cl.configstrings[CS_ITEMS + idx]`. Drawn today by `CL_DrawInventory()`
(`client/cl_inventory.c:62–160`). Perfect source for a scrollable wrist
inventory.

### 1.3 The help computer / objectives — the in-fiction "computer"

Built server-side in `HelpComputerMessage()` (`game/player/hud.c:327–373`) and
shipped to the client as a single pre-formatted `svc_layout` string stored in
`cl.layout[1024]` (`client/cl_parse.c:1384–1387`,
`client/header/client.h:162`). It contains:

- skill level, **level name** (`level.level_name`),
- **primary objective** (`game.helpmessage1`) and **secondary objective**
  (`game.helpmessage2`) — set by `target_help` entities (`game/g_target.c:189`),
- **kills / goals / secrets** counters (`level.killed_monsters /
  total_monsters`, `found_goals/total_goals`, `found_secrets/total_secrets`).

Caveat: this string is only sent when the player opens help (F1 →
`Cmd_Help_f`, `game/g_cmds.c:635`), so the counters are a *snapshot at open
time*, not continuous. Level name is always available via `CS_NAME` (configstring
0). See §6 for how we get *live* objective progress.

### 1.4 Center-print messages — story / pickup / objective text

`svc_centerprint` → `SCR_CenterPrint(string)` (`client/cl_parse.c`). Carries
"You got the X", "Now available: …", story beats, computer logs, death notices.
High-value, human-readable text for the watch ticker.

### 1.5 Events & sounds we can mirror

Parsed in `client/cl_parse.c` (svc dispatch) — verified enum in
`common/header/common.h:188–216`:

- **`svc_sound`** → `CL_ParseStartSoundPacket()` (`cl_parse.c:1150`): carries
  `sound_num` (→ name `cl.configstrings[CS_SOUNDS + sound_num]`), entity,
  channel (`CHAN_WEAPON/VOICE/BODY/AUTO`), volume, attenuation, position. Lets us
  identify *what* sound played (pain, pickup, weapon, door) and mirror a curated
  subset to the watch.
- **`svc_muzzleflash`** → `CL_AddMuzzleFlash()` (`client/cl_effects.c`): entity +
  weapon code (`MZ_BLASTER/MACHINEGUN/SHOTGUN/RAILGUN/ROCKET/BFG/…`, `MZ_SILENCED`
  flag). → "weapon fired" event + which weapon.
- **`svc_temp_entity`** → `CL_ParseTEnt()` (`client/cl_tempentities.c:643`):
  `TE_GUNSHOT/BLOOD/EXPLOSION1/ROCKET_EXPLOSION/SPLASH/…` + position. → impact /
  explosion effects.
- **`svc_print`** (`PRINT_CHAT`) — chat lines. → watch ticker.
- **`STAT_FLASHES`** (§1.1) — the cleanest "I just took damage" signal for a
  damage **haptic**.

### 1.6 Configstrings — the lookup tables (`shared.h:1019–1037`)

`CS_NAME=0` (level name), `CS_STATUSBAR=5` (HUD layout program),
`CS_MODELS=32`, `CS_SOUNDS=CS_MODELS+256`, `CS_IMAGES=CS_SOUNDS+256`,
`CS_ITEMS=CS_LIGHTS+256` (item names), `CS_PLAYERSKINS` (player names). The watch
needs **`CS_NAME`**, **`CS_ITEMS`** (item/weapon names) and optionally a
curated **`CS_SOUNDS`** map. These are static per map — send once on map load,
not every frame.

### 1.7 The send path already exists

`CL_Frame()` (`client/cl_main.c:746`) calls `CL_ReadPackets()` (`:792`, state is
freshest right after), then renders. `NET_SendPacket(netsrc_t, len, data,
netadr_t)` (`common/netchan.c` → `backends/unix/network.c:582`) already sends raw
UDP from the bound client socket. `NET_StringToAdr()` turns `"192.168.1.50:27999"`
into a `netadr_t`. **We need no new socket — just a cvar, a netadr, and a call.**

---

## 2. Architecture

```
┌──────────────────────────┐     UDP/LAN      ┌────────────────┐   WatchConnectivity   ┌─────────────────┐
│  Old Mac — Quake II       │  ~10 Hz state +  │  iPhone app     │  sendMessage /        │  Apple Watch    │
│  cl_watchlink.c (gated)   │ ──── events ───▶ │  NWListener UDP │ ──updateAppContext──▶ │  "Tactical      │
│  watch_host "<phone ip>"  │  newline JSON    │  state model    │                       │   Computer" UI  │
└──────────────────────────┘                  │  + relay        │                       │  haptics+sound  │
                                              └────────────────┘                       └─────────────────┘
```

**Why the iPhone in the middle?** watchOS can open sockets (Network framework,
watchOS 6+) but background/Wi-Fi UDP listening is unreliable and power-hungry.
The proven pattern is: iPhone holds the socket and pushes to the watch via
WatchConnectivity (`sendMessage` when reachable for low latency,
`updateApplicationContext` for latest-wins state). This also gives a natural place
to configure the Mac/phone IPs and to pair. *(A direct Mac→Watch `NWConnection`
is possible and simpler to ship for a single-room hobby setup — listed as an
alternative in §7.)*

**Transport format: newline-delimited JSON.** Rationale specific to this fleet:
the PPC Macs are **big-endian**, so a hand-rolled binary struct invites byte-order
bugs (see CLAUDE.md / MISTAKES ethos). JSON via `snprintf` is endianness-proof,
trivially debuggable with `nc -ul 27999`, and at ~10 Hz × ~250 bytes is free even
over AirPort. Two packet kinds:

```
{"t":"vitals","hp":87,"ap":50,"ammo":24,"wpn":"Super Shotgun","frags":3,
 "pu":{"icon":"quad","sec":18},"flash":1,"layouts":0,"spec":0}\n
{"t":"event","kind":"centerprint","msg":"You got the Railgun"}\n
{"t":"event","kind":"damage","amount":12,"src":"health"}\n
{"t":"meta","level":"Outer Base","items":["Shells","Bullets",...]}\n   // on map load
```

---

## 3. The engine patch (`src/client/cl_watchlink.c`)

New, self-contained file. **Off by default; zero cost when `watch_host` is empty
— no socket traffic, no per-frame work** (satisfies the "must be runtime-gated /
no fleet risk" rule; this is *not* a load-time-only change).

**Cvars**
- `watch_host ""` — phone/watch IP+port; empty ⇒ feature fully disabled.
- `watch_rate "10"` — heartbeat Hz.
- `watch_events "1"` — mirror discrete events.

**Public API (called from existing code, all guarded by `watch_host[0]`):**
- `CL_WatchLink_Init()` — register cvars (call from `CL_Init`).
- `CL_WatchLink_Frame()` — append to end of `CL_Frame()` (`cl_main.c`, after
  `CL_ReadPackets`); throttle to `watch_rate`; snapshot `cl.frame.playerstate.stats[]`,
  resolve weapon name via `cl.configstrings[CS_ITEMS + stats[STAT_SELECTED_ITEM]]`,
  build a `vitals` line, `NET_SendPacket`.
- `CL_WatchLink_Event(kind, …)` — fire-and-forget event line. Hook sites:
  - `SCR_CenterPrint()` → `kind:"centerprint"` (objective/pickup/story text).
  - `CL_ParseStartSoundPacket()` → `kind:"sound"` with resolved `CS_SOUNDS` name
    (filter to a curated set client-side).
  - `STAT_FLASHES` transition in `CL_WatchLink_Frame()` → `kind:"damage"`.
  - `svc_layout` arrival → `kind:"objectives"` (parse `cl.layout`, see §6).
- `CL_WatchLink_Meta()` — on map load (after `CL_PrepRefresh`), send `CS_NAME` +
  the `CS_ITEMS` name table once.

**Send helper:** keep a cached `netadr_t` (re-resolve when `watch_host` changes
via `NET_StringToAdr`), build the line with `snprintf`, `NET_SendPacket(NS_CLIENT,
len, buf, watch_adr)`. ~120 lines total. No new platform code.

**Build:** add the one file to the client source list (Makefile / CMake). Builds
identically on g3/g4/g5/lion; nothing endianness-sensitive ships.

---

## 4. iPhone companion app (SwiftUI)

- **`UDPListener`** (Network framework `NWListener`, UDP, port 27999): receives
  newline-JSON, decodes into a `GameState` observable model.
- **Config screen:** enter the Mac's display target = *this phone's* IP (shown in
  the app) so you paste it into `set watch_host` on the Mac; pick port.
- **`WatchSession`** (`WCSession`): `updateApplicationContext` for the latest
  `vitals` (latest-wins, survives lulls); `sendMessage` for discrete events when
  the watch is reachable (low-latency haptics).
- **Debug HUD:** mirror the watch UI on the phone for development without the
  watch on-wrist.

---

## 5. watchOS app — the Tactical Computer (SwiftUI)

Aesthetic: Quake II marine-terminal — amber/green phosphor on near-black,
blocky `Q2` numerals, scanline texture, the help-computer chrome.

**Views**
1. **Vitals** (default): big HP, ARMOR + AMMO gauges, selected-weapon name,
   powerup countdown ring (`STAT_TIMER`), frags. Red flash + **haptic** on
   `damage` events (`.notification(.failure)` / custom `WKHapticType`).
2. **Inventory** (Digital Crown scroll): item names + quantities from the meta
   item table × the inventory snapshot.
3. **Mission / Objectives**: level name (always live) + primary/secondary
   objective + kills/goals/secrets bars (from §6). This is the on-wrist
   recreation of the F1 help computer.
4. **Ticker**: rolling center-print / chat log.

**Sound:** bundle a curated set of short clips mapped from `CS_SOUNDS` names
(pain, item pickup, ammo pickup, weapon fire, door, computer beep) and play via
`WKInterfaceDevice`/`AVAudioPlayer` on matching `sound` events.

**Complication / Smart Stack:** current HP as a corner/gauge complication.

---

## 6. Getting *live* objective progress (optional, Phase 4)

The kill/goal/secret counters live server-side (`level.*`) and only reach the
client inside the F1 `svc_layout` snapshot. Two options:

- **A (no game-DLL change, ship first):** parse `cl.layout` whenever it arrives
  (player opens help) → objectives + a counter snapshot. Level name is always live
  via `CS_NAME`. Good enough for v1.
- **B (game-DLL change, later):** in `game/`, periodically (e.g. every 2 s in
  `ClientEndServerFrame`) pack `killed/total monsters, goals, secrets,
  helpmessage1/2` into a spare configstring or a `stat`, so the watch shows a
  *live* objective tracker. Bigger surface area — defer until A proves the concept.

---

## 7. Risks, constraints & fleet rules

- **Opt-in / zero fleet risk.** `watch_host ""` ⇒ no sockets, no per-frame cost.
  Default-off means benchmarks and the DMG behave identically. (Directly answers
  the MISTAKES "easy / load-time / zero-risk" trap: this is *runtime*-gated, not
  load-time-magic.)
- **Big-endian PPC.** JSON transport avoids all byte-order hazards. Do **not**
  hand-roll a binary struct without explicit LE conversion.
- **Don't touch the PPC build / smoke tests.** One new client file, behind a cvar.
  Add a smoke check: launch with `watch_host` set to a dead IP and confirm a clean
  `demo1` auto-exit (no hangs from a blocked `sendto`). Keep sends non-blocking.
- **Same LAN.** AirPort/Ethernet Macs and the iPhone must share the subnet; pick a
  fixed UDP port (e.g. 27999, distinct from 27910 game traffic).
- **Send cost.** ~10 Hz × one small UDP packet is negligible even on the G3; keep
  the `snprintf`+`sendto` off the render hot path (end of frame, throttled).

---

## 8. Phased delivery

| Phase | Deliverable | Validation |
|------|-------------|-----------|
| **0** | Protocol spec + `nc -ul 27999` / 30-line Python listener | see JSON on the desktop |
| **1** | `cl_watchlink.c` — vitals heartbeat + damage/centerprint events, cvar-gated | Python listener prints live HP while you play a demo |
| **2** | iPhone app — UDP listener + state model + WCSession relay | phone HUD mirrors the Mac |
| **3** | watchOS app — Vitals + Inventory + Mission views; damage haptics | full loop on-wrist |
| **4** | Sounds, complication, aesthetic polish; optional live objectives (§6B) | "feels like the in-game computer" |

**Recommended first step:** Phase 0 + Phase 1 entirely on the desktop — patch the
engine, point `watch_host` at the Mac itself, and watch the JSON stream with
`nc`. That validates the whole data side before a line of Swift.

---

## 9. Open questions for you

1. **iPhone relay vs. direct Mac→Watch** `NWConnection` (simpler, single-room
   only)? Plan assumes relay for reliability.
2. **Binary protocol** ever needed, or is JSON fine forever? (Recommend JSON.)
3. Scope of **sound mirroring** — full curated set, or just damage haptics + a
   couple of stings to start?
4. Want me to **scaffold `cl_watchlink.c` + the Python listener now** (Phase 0/1)
   so you can see the feed today?
