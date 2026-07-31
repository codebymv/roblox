# Roblox — Co-op Cargo Catastrophe

Prototype project for a **Co-op Operational Catastrophe** experience on Roblox:

> Up to four crews share one depot. Each crew hauls cargo leg by leg, and after every delivery votes to bank the stack or push for a harder, richer leg. One bad strap, turn, or repair cascades into a readable disaster that forfeits everything unbanked.

This folder is intentionally separate from the UE5 PlatypunkGame repo.

## Two builds, one switch

`src/Shared/DevConfig.lua` decides which game boots.

| Mode | What runs | What it is for |
|---|---|---|
| `FunTest` **(current default)** | `TruckLab`: one crew, one physics truck, one route, one crate | Answering whether the core interaction is fun at all |
| `Depot` | `DepotService`: four bays, economy, persistence, kits, leg ladder | The full meta build |

Nothing is deleted between the two. In `FunTest` the depot, economy, persistence,
shop, live-ops and leg ladder simply never initialise, so there is no DataStore
traffic and nothing standing between a player and the truck.

The prototype was moved into `FunTest` after
[Docs/CoreFunAudit_V0.md](Docs/CoreFunAudit_V0.md) found that the truck was an
anchored, non-collidable model repositioned by `PivotTo`, that cargo condition
was a single scalar the visuals obeyed rather than reported, and that only the
Driver had continuous input.

## Structure

```
roblox/
  README.md
  Docs/                     Brief, DNA analysis, core-fun audit, playtest protocol
  src/Shared/               Config, types, manifests, kits, live-ops, networking
  src/Server/               Fun-test lab, physics truck, depot, economy, persistence
  src/Client/               Lab HUD and debug overlay, crew HUD, depot panel
  Tests/StudioSmoke.luau    Engine-level smoke test, branches on DevConfig.Mode
  default.project.json      Rojo project map
```

## Docs

| Doc | Purpose |
|---|---|
| [Docs/CoreFunAudit_V0.md](Docs/CoreFunAudit_V0.md) | Why the prototype was not producing the fantasy, and what the fun-test build bypasses |
| [Docs/PlaytestProtocol_V0.md](Docs/PlaytestProtocol_V0.md) | Four-player test script, what not to explain, go/no-go criteria |
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

## The fun-test loop (`DevConfig.Mode = "FunTest"`)

One truck, one crate, one road. A run starts a couple of seconds after you join
and restarts a couple of seconds after it ends.

**The truck is real.** An unanchored, collidable chassis on four raycast
suspension springs. Cornering comes from traction-limited lateral grip at each
contact patch, so lifting a wheel genuinely costs you grip, and the truck can
roll over. Network ownership is pinned to the server, because server-applied
forces and client physics ownership cannot coexist; the driver pays one round
trip of input latency for a truck every player sees identically.

**The load is real.** A crate with mass sits on the bed held by four ropes to
its top corners. Strap tension is computed from the chassis's measured
acceleration and the actual rope geometry, tension over a threshold wears a
strap down, and a strap at zero health snaps. Nothing writes a stability number:
the HUD's condition percentage is read back out of where the crate physically
is.

Condition runs `Secure → Shifted → Leaning → Sliding → PartiallyDetached →
Hanging → Dragging → Lost`, and each state is a measurement, not a flag. A
dragging crate applies real drag and hauls the truck off line through its own
straps.

**Pressure, not outcomes.** Three categories replace the eight authored
failures: weaken a named strap, sag a suspension corner or soften the steering,
or push the truck sideways. The director never assigns damage. The road does the
rest, through a blind right-hander with adverse camber, a long descent, a broken
surface, and a bridge with nothing either side of it.

### Fun-test controls

- **Driver:** `WASD` or arrows, `Space` to brake.
- **Crew:** `1`-`4` to commit to a strap station, hold `E` to work the strap you
  are standing at. Crossing the bed takes time and cannot be cancelled, and
  enough lateral load throws you off.
- **`T`** hands over or takes the wheel. **`R`** restarts. **`F`** toggles the
  tuning overlay (off it goes before you show anyone).

Crew are welded into the chassis assembly rather than walking on it: humanoids
do not stay on a platform moving at 60 studs per second. They therefore visibly
sit at their stations, which is cosmetic debt to be repaid, not a design choice.

## The depot loop (`DevConfig.Mode = "Depot"`)

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

### Fun-test build

| Module | Responsibility |
|---|---|
| `src/Server/TruckLab.lua` | The whole fun-test session: phases, roles, remotes, restart |
| `src/Server/PhysicsChassis.lua` | Raycast-suspension truck, grip, steering, impact and rollover |
| `src/Server/CargoLoad.lua` | Roped crate, per-strap tension and health, derived condition |
| `src/Server/StrapperStations.lua` | Station occupancy, committed traversals, counterweight, throws |
| `src/Server/PressureDirector.lua` | Three pressure categories that perturb state, never outcomes |
| `src/Server/LabTelemetry.lua` | Per-run event log printed to the server output |
| `src/Server/RateLimiter.lua` | Token bucket in front of every client intent remote |

### Depot build

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
