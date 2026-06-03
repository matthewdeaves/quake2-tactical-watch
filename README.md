# Quake II Tactical Computer — Apple Watch companion

Turn your wrist into the Quake II marine's in-fiction **help computer**. An old
Mac running Quake II ([old-mac-quake2](https://github.com/matthewdeaves/old-mac-quake2),
branch `watch-tactical-computer`) emits a live UDP feed of the player's state —
health, armor, ammo, inventory, mission objectives, damage, pickups. An iPhone
app receives it on the LAN and relays it to an Apple Watch app that renders the
amber-phosphor terminal, with haptics on damage and sounds on events.

```
Old Mac (Quake II)  ──UDP/JSON──▶  iPhone (relay)  ──WatchConnectivity──▶  Apple Watch
  cl_watchlink.c                    NWListener                              Tactical Computer UI
  (off unless watch_host set)       GameState model                        haptics + sounds
```

## Status

- ✅ **Engine side** (the UDP feed) — shipped in the
  [old-mac-quake2](https://github.com/matthewdeaves/old-mac-quake2) repo.
- ⬜ **iPhone + watchOS apps** — this repo. Not started.

## Start here

Read [`PLAN.md`](PLAN.md) — the full design (engine code review, architecture,
wire format, phased delivery). Phase 2 (iPhone) is the next deliverable.

## Wire format

Newline-delimited JSON over UDP, port 27999. See `PLAN.md` §2.

## License

The engine patch is GPLv2 (Quake II). App code in this repo: TBD.
