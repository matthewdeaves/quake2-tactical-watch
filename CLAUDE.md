# Quake II "Tactical Computer" — Apple Watch companion

This repo is the **client side** (iPhone + Apple Watch app) of a companion that
turns the player's wrist into Quake II's in-fiction help computer — live health,
armor, ammo, inventory, mission objectives, damage haptics, and event sounds.

**Read `PLAN.md` first** — it is the authoritative design doc (deep code review
of the engine + full architecture + phased delivery). Everything you build here
should trace back to it.

## The other half (already done)

The **engine side** lives in a separate repo and is already shipped:
`~/Documents/old-mac-quake2`, branch `watch-tactical-computer`. It adds
`src/client/cl_watchlink.c`, a cvar-gated UDP feed that emits newline-delimited
JSON of live player state and events. It is **off by default** (`watch_host ""`).

Wire format (authoritative copy in `PLAN.md` §2; mirror, don't diverge):

```
{"t":"vitals","hp":87,"ap":50,"ammo":24,"wpn":"Super Shotgun","frags":3,
 "pu":{"icon":"quad","sec":18},"flash":1,"layouts":0,"spec":0}\n
{"t":"event","kind":"centerprint","msg":"You got the Railgun"}\n
{"t":"event","kind":"damage","amount":12,"src":"health"}\n
{"t":"event","kind":"psound","msg":"jump1"}\n            // local-player SFX basename (incl. "pc_up" beep)
{"t":"event","kind":"objectives","skill":"medium","loc":"Outer Base","obj1":"...","obj2":"","kills":"5/20","goals":"0/0","secrets":"1/2"}\n
{"t":"meta","level":"Outer Base","items":["Shells","Bullets",...]}\n
```

UDP, default port **27999** (distinct from Quake's 27910). The PPC Macs are
big-endian — the transport is JSON precisely to stay endianness-proof; keep it
that way.

`objectives` mirrors the F1 help computer (structured fields). It streams
**automatically** during play: the game DLL silently unicasts the help layout
tagged `"watchlink "`, and the client forwards it to the companion *without*
drawing the F1 overlay — so the wrist shows objectives/kills/secrets with no
in-game interaction. The menu attract-loop demo is gated out (never drives the
companion), and Bonjour auto-discovery is time-bounded (~30 s) so a phoneless
game costs no CPU.

## How to test the feed without the watch

The engine repo ships `scripts/watchlink-listen.py` — a desktop listener. Point
the game's `watch_host` cvar at your dev machine and run it to see the live JSON.
That validates the whole data side before any Swift.

## What to build here (from PLAN.md §4–5, §8)

- **Phase 2** — iPhone app (SwiftUI): `NWListener` UDP socket → `GameState`
  observable → relay to the watch via `WCSession`
  (`updateApplicationContext` for vitals, `sendMessage` for events).
- **Phase 3** — watchOS app: Vitals / Inventory / Mission views + damage haptics.
- **Phase 4** — curated sounds, HP complication, amber-phosphor terminal polish.

Aesthetic: Quake II marine terminal — amber/green phosphor on near-black, blocky
numerals, scanlines, the help-computer chrome.

## Conventions

- This is a fresh repo with **no Xcode project yet** — scaffold one when you start
  Phase 2 (an iOS app target + a watchOS app target in one workspace).
- Keep the wire protocol in sync with `cl_watchlink.c` in the engine repo. If you
  change the format, change both sides and update `PLAN.md`.
