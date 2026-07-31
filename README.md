# Roblox — Co-op Cargo Catastrophe

Prototype project for a **Co-op Operational Catastrophe** experience on Roblox:

> Up to four crews share one depot. Each crew hauls cargo leg by leg, and after every delivery votes to bank the stack or push for a harder, richer leg. One bad strap, turn, or repair cascades into a readable disaster that forfeits everything unbanked.

This folder is intentionally separate from the UE5 PlatypunkGame repo.

## Structure

```
roblox/
  README.md
  Docs/                     Prototype brief, DNA analysis, metrics, slice contract
  src/Shared/               Config, types, manifests, kits, live-ops, networking
  src/Server/               Persistence, economy, depot, per-crew match, rigs
  src/Client/               Crew HUD, depot panel, nameplates
  Tests/StudioSmoke.luau    Engine-level smoke test
  default.project.json      Rojo project map
```

## Docs

| Doc | Purpose |
|---|---|
| [Docs/PrototypeBrief_CargoCatastrophe_V0.md](Docs/PrototypeBrief_CargoCatastrophe_V0.md) | Product pitch, loop, roles, exclusions, kill/go |
| [Docs/TopGameDNA_V0.md](Docs/TopGameDNA_V0.md) | Top-10 structural audit and the patterns we adopted or declined |
| [Docs/ValidationMetrics_V0.md](Docs/ValidationMetrics_V0.md) | What to measure in playtests |
| [Docs/BuildChecklist_V0.md](Docs/BuildChecklist_V0.md) | Vertical-slice build checklist |
| [Docs/VerticalSlice_CargoRun_V0.md](Docs/VerticalSlice_CargoRun_V0.md) | One-map build target (vehicle, route, failures) |
| [Docs/SystemsReuseMap_V0.md](Docs/SystemsReuseMap_V0.md) | Cross-repo contracts adopted into this prototype |

## Tooling

1. Install [Rojo](https://rojo.space/) (`rojo --version`).
2. From this folder, either build a place or serve into Studio:

```powershell
rojo build default.project.json --output CargoCatastrophe.rbxlx
rojo serve
```

3. In Studio, connect the Rojo plugin to the serve session.

**Enable DataStores before testing progression.** Game Settings → Security → *Enable Studio Access
to API Services*. Without it the server runs profiles in volatile mode: everything works, nothing
saves, and it says so once in the output.

## The loop

The server is a **depot** with four bays. Each bay is one crew of up to four on its own parallel
route lane, visible to everyone else in the yard.

1. **Spawn → auto-crewed** into the emptiest open bay. Step on another bay pad to switch.
2. **Staging** departs on its own: about 5 seconds solo, 14 with a forming crew. Ready or *Roll Out
   Now* skips the wait.
3. **Leg N** rolls a cargo from the manifest (rarity, value multiplier, one mechanical quirk) and
   runs a shorter clock and higher failure pressure than the leg before it.
4. **Delivery Hold** lights the zone. Stop inside it to complete the leg.
5. **Bank or Push** — twelve seconds. Majority rules, a tie banks, a timeout banks. Bank pays every
   crew member the full stack in Freight Credits; push doubles down on a harder leg.
6. **A wipe forfeits the whole unbanked stack** and resets your convoy streak.

Credits buy permanent per-role kits from the Outfitter (widen timing windows, raise safe corner
speed, restore more integrity) and cab paint. Nothing purchasable skips an interaction.

### Controls

- **Driver (keyboard):** `WASD` or arrow keys; hold `Space` to brake.
- **Driver (touch):** on-screen left/right, Go, Reverse, and Brake buttons.
- **Spotter:** tap **Ping Hazard** when the warning appears.
- **Strapper / Repair:** hold the contextual action button until the save completes.
- **Depot panel:** `Tab` or the DEPOT button — bays, Outfitter, standings, daily bonus.

Leg 1 always opens with a guaranteed, generously timed save moment chosen from a role the crew
actually has, so a first session hits the core interaction within seconds rather than watching a
cascade it cannot answer.

Solo remains playable: a lone player is always Driver, and the opening beat becomes the corner
brake instead of a strap only a Strapper could fix.

## Server layout

| Module | Responsibility |
|---|---|
| `src/Server/PlayerDataService.lua` | DataStore profiles, session cache, autosave, `BindToClose` |
| `src/Server/EconomyService.lua` | Sole authority for payouts, streaks, purchases |
| `src/Server/WorldBuilder.lua` | Depot hub, board, four parallel lanes |
| `src/Server/DepotService.lua` | Bays, membership, spectating, remotes, depot snapshot |
| `src/Server/CrewMatch.lua` | One crew's phase machine and leg ladder |
| `src/Server/CargoRig.lua` | One crew's truck |
| `src/Server/FailureRunner.lua` | One crew's failure cadence |
| `src/Server/RoleService.lua` | One crew's role assignment and kit effects |

## Out of scope (v0)

Trading, gacha pulls, open world, seasons, voice-only puzzles, paid power. See the declined-patterns
list in [Docs/TopGameDNA_V0.md](Docs/TopGameDNA_V0.md) for why.
