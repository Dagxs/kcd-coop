# kcd-coop

Experimental co-op for **Kingdom Come: Deliverance** (the 2018 original). Early prototype: two players
see each other walking around their own single-player worlds. No shared enemies, quests or story yet.

Built with the [Co-op Anything](https://github.com/cranebeaker/coop-anything) playbook. Research notes,
offsets and test results: `games/kingdom-come-deliverance/NOTES.md` in
[Dagxs/coop-anything](https://github.com/Dagxs/coop-anything/tree/game/kingdom-come-deliverance).

## What works (tested 2026-10-25, two copies on one Windows PC)

- A loader (`dinput8.dll`) that runs inside the game, can run the game's own Lua scripts, and reads the
  player's position and facing.
- Each game sends its player's position to the other about 10 times a second over UDP.
- The other player appears as a stand-in character that moves smoothly and switches between idle,
  walk and run animations depending on speed.
- The stand-in is a real NPC made to look like Henry (his head, hair and current clothes), with its
  AI brain switched off so only the other player's data moves it (`lua/coop_core.lua`).
- Gear matching: the stand-in wears the other player's actual clothes and armour, updated within ~2 s
  when they change (worn items are read from the engine's equipment handler; see NOTES).

QA level: manual (owner-observed, loader logs). No automated tests yet.

## What doesn't (yet)

- Shared: position, facing, walk/run state, worn gear, carried weapons, drawn/holstered, and an approximate
  combat stance + sword swing when the other player attacks in a real fight (direction is guessed).
  No real hit directions, blocks, shared enemies, quests or story.
- Direct UDP only (same PC or LAN, or port forwarding). Steam relay is planned.
- Only one game build is supported (below). The loader checks every address and does nothing on a mismatch.

## Supported build

| | |
|---|---|
| Store | Steam |
| Game version | 1.9.8 (`wh_sys_version`), exe FileVersion 1.9.7.0 |
| WHGame.dll SHA-256 | `cf9f6dc384edcf35c20647a912745ddb8adb5ba65953e329c24e89dd9c4381aa` |
| KingdomCome.exe SHA-256 | `cde5c7d03e76abef91b5dfbcd4e2ccf070ab4811a0fc652b429dacf5559bca73` |

## Try it (testers)

Work on a **copy** of the game, not your Steam install.

1. Copy `<game dir>` (the whole `KingdomComeDeliverance` folder) somewhere else, e.g. `E:\KCD-coop-test`.
2. Build or download `dinput8.dll` and put it in the copy's `Bin\Win64` next to `KingdomCome.exe`.
3. For two copies on one PC: run `python tools/make_second_launcher.py "<copy>\Bin\Win64\KingdomCome.exe"`
   to create `KingdomCome2.exe`. Start `KingdomCome.exe` (player A) and `KingdomCome2.exe` (player B).
4. For two PCs: on each, create `kcdcoop_A.ini` (or `_B`) in the copy's root folder:
   ```
   bind=64200
   peer=<other PC's IP>:64200
   ```
5. Load a save in both. The loader writes `kcdcoop.log` in the copy's root folder.

Remove `dinput8.dll` to uninstall.

## How it works

- `loader/dinput8.c`: proxy for `dinput8.dll`, which the game loads from its own folder. It forwards
  `DirectInput8Create` to the real Windows DLL, then:
  - finds the game console (`gEnv->pConsole`) and runs Lua through `ExecuteString(cmd, silent, defer)`,
    so scripts run on the game's main thread;
  - skips the dev-mode check that blocks console Lua (one 2-byte patch, verified first);
  - reads data back through a console variable that Lua writes;
  - sends and receives positions over UDP, smooths them, and calls Lua `CoopSetRemote(x, y, z, rot, speed)`;
  - runs `kcdcoop_cmd_A.lua` / `kcdcoop_cmd_B.lua` dropped into the game root (live scripting for development).
- `lua/coop_core.lua`: the game-side half, embedded into the DLL at build time: spawns the stand-in as an
  NPC with Henry's look and its AI brain off, moves it (`CoopSetRemote`), and picks idle / walk / run from
  the remote player's speed. Other files in `lua/` are one-off exploration jobs for the command file.
- `tools/`: small PE analysis helpers (string and data cross-references, disassembly) used to find the offsets.

## Build

```
pip install ziglang
./build.sh
```

## License

MIT. Contains no game files or assets; you need your own copy of the game.
