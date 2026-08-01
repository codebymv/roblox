# Roblox · Co-op Cargo Catastrophe

Prototype project for a **Co-op Operational Catastrophe** experience on Roblox:

> Up to four crews share one depot. Each crew hauls cargo leg by leg, and after every delivery votes to bank the stack or push for a harder, richer leg. One bad strap, turn, or repair cascades into a readable disaster that forfeits everything unbanked.

This folder is intentionally separate from the UE5 PlatypunkGame repo.

## Two builds, one switch

`src/Shared/DevConfig.lua` decides which game boots.

| Mode | What runs | What it is for |
|---|---|---|
| `FunTest` **(current default)** | `TruckLab`: one crew, one physics truck, one route, persistent rewards and truck paint | Public playtest and progression validation |
| `Depot` | `DepotService`: four bays, economy, persistence, kits, leg ladder | The full meta build |

Nothing is deleted between the two. In `FunTest` the old depot, role kits,
live-ops and leg ladder never initialise. The shared profile cache now records
Cargo Cash and truck-paint ownership around the current physics run.

Tooling profiles are separate from the mode switch. Studio automatically uses
`Development` (debug overlay, live tuning, commands, and run artifacts), while
published servers use a fail-closed `Release` profile with only server telemetry
left on. The fun-test place is capped to one four-player crew.

The prototype was moved into `FunTest` after
[Docs/CoreFunAudit_V0.md](Docs/CoreFunAudit_V0.md) found that the truck was an
anchored, non-collidable model repositioned by `PivotTo`, that cargo condition
was a single scalar the visuals obeyed rather than reported, and that only the
Driver had continuous input.

## Structure

```
roblox/
  README.md
  Docs/                     Design intent; Docs/README.md says what is still current
  src/Shared/               Config, types, tuning schema, manifests, kits, networking
  src/Server/               Fun-test lab, physics truck, depot, economy, persistence
  src/Client/               UI kit, lab HUD and debug overlay, crew HUD, depot panel
  Tests/                    Headless suite (Lune, in CI) and Studio smoke test
  rokit.toml                Pinned toolchain
  default.project.json      Rojo project map
```

## Docs

Start with [Docs/README.md](Docs/README.md), which sorts the eight design
documents by whether they still describe the build. The two worth reading first
are [Docs/CoreFunAudit_V0.md](Docs/CoreFunAudit_V0.md), on why the depot
prototype was not producing the fantasy, and
[Docs/PlaytestProtocol_V0.md](Docs/PlaytestProtocol_V0.md), which is the next
thing that happens to the project.

## Tooling

The toolchain is pinned in `rokit.toml`. Install [Rokit](https://github.com/rojo-rbx/rokit),
then from this folder:

```powershell
rokit install
rojo serve
```

Connect the Rojo plugin in Studio to the serve session, or build a place file
directly:

```powershell
rojo build default.project.json --output CargoCatastrophe.rbxlx
```

Before pushing, run what CI runs:

```powershell
stylua src Tests
selene src Tests
lune run Tests/Headless.luau
```

**Enable DataStores before testing progression.** Game Settings → Security → *Enable Studio Access
to API Services*. Without it the server runs profiles in volatile mode: everything works, nothing
saves, and it says so once in the output. Studio uses a separate test store, so these checks cannot
overwrite live player balances.

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

### Tuning it without restarting

`LabConfig` is read at the point of use · `PhysicsChassis:step` reads
`LabConfig.GripFront` inside the wheel loop rather than hoisting it · so writing
a new value into the table lands on the next frame. `TuningService` exploits
that: select `ReplicatedStorage.LabTuning` in the Explorer and edit an attribute
in the Properties pane. There is no bespoke tuning UI to maintain, because
Studio already ships a perfectly good attribute editor.

Two attributes are commands rather than values. `ACTION_Dump` prints the values
you have moved, formatted to paste back into `LabConfig.lua`; `ACTION_Reset`
restores the file defaults. `src/Shared/TuningSchema.lua` decides what is
exposed and which values need a rig rebuild rather than taking effect live.

The corner sits at roughly 6-19% of a 4,000 stud route, so the debug overlay
(`F`) can warp the truck to a given route progress and rebuild the rig after a
build-time constant changes. Tuning grip does not mean driving to the corner
again.

Each run then writes itself to `ServerStorage.LabRuns` as JSON: the input
stream, the event timeline, the outcome, and the tuning values that produced it.
Studio's output window is live-only, host-only and scrolls away; a run file can
be compared against the run before it. Do not expect replay · Roblox's solver
does not give determinism, so this is for comparison, not reproduction.

## The depot loop (`DevConfig.Mode = "Depot"`)

The server is a **depot** with four bays. Each bay is one crew of up to four on its own parallel
route lane, visible to everyone else in the yard.

1. **Spawn → auto-crewed** into the emptiest open bay. Step on another bay pad to switch.
2. **Staging** departs on its own: about 5 seconds solo, 14 with a forming crew. Ready or *Roll Out
   Now* skips the wait.
3. **Leg N** rolls a cargo from the manifest (rarity, value multiplier, one mechanical quirk) and
   runs a shorter clock and higher failure pressure than the leg before it.
4. **Delivery Hold** lights the zone. Stop inside it to complete the leg.
5. **Bank or Push** · twelve seconds. Majority rules, a tie banks, a timeout banks. Bank pays every
   crew member the full stack in Freight Credits; push doubles down on a harder leg.
6. **A wipe forfeits the whole unbanked stack** and resets your convoy streak.

Credits buy permanent per-role kits from the Outfitter (widen timing windows, raise safe corner
speed, restore more integrity) and cab paint. Nothing purchasable skips an interaction.

### Controls

- **Driver (keyboard):** `WASD` or arrow keys; hold `Space` to brake.
- **Driver (touch):** on-screen left/right, Go, Reverse, and Brake buttons.
- **Spotter:** tap **Ping Hazard** when the warning appears.
- **Strapper / Repair:** hold the contextual action button until the save completes.
- **Depot panel:** `Tab` or the DEPOT button · bays, Outfitter, standings, daily bonus.

Leg 1 always opens with a guaranteed, generously timed save moment chosen from a role the crew
actually has, so a first session hits the core interaction within seconds rather than watching a
cascade it cannot answer.

Solo remains playable: a lone player is always Driver, and the opening beat becomes the corner
brake instead of a strap only a Strapper could fix.

## Server layout

### The spine

These carry no opinion about trucks or cargo, and are the part of this repo
worth copying into a second title. The game layer below is not.

| Module | Responsibility |
|---|---|
| `src/Shared/DevConfig.lua`, `src/Shared/BuildProfiles.lua` | The mode switch and automatic Development/Release tooling boundary |
| `src/Server/LabSession.lua` | Session lifecycle: phases, join and leave, the step loop, snapshots |
| `src/Shared/LabRemotes.lua` | Every remote declared with its payload type and a server-side validator |
| `src/Shared/TuningSchema.lua`, `src/Server/TuningService.lua` | What is tunable, and live editing of it through attributes |
| `src/Server/DevCommands.lua` | Warp, rebuild and dump, rate limited like any other remote |
| `src/Server/LabTelemetry.lua` | Run timeline and the JSON artifact in `ServerStorage.LabRuns` |
| `src/Server/LabAnalytics.lua` | Published-server onboarding funnel, run outcomes, session metrics, and structured feedback |
| `src/Server/PlayerDataService.lua` | Shared DataStore profile cache, autosave, volatile fallback, and `BindToClose` |
| `src/Shared/LabProgression.lua`, `src/Server/LabProgressionService.lua` | Testable run rewards plus the persistent Cargo Cash and paint adapter |
| `src/Shared/TokenBucket.lua`, `src/Server/RateLimiter.lua` | Throttling, split into engine-free maths and a Player-keyed wrapper |
| `src/Shared/RouteMath.lua` | Arc-length progress and its inverse, dependency-free |
| `src/Client/UIKit.lua` | Panels, labels and buttons, plus setters that skip unchanged writes |

### Fun-test build

| Module | Responsibility |
|---|---|
| `src/Server/TruckLab.lua` | Composition root: builds the route, owns one `LabSession`, wires dev commands |
| `src/Server/PhysicsChassis.lua` | Raycast-suspension truck, grip, steering, impact and rollover |
| `src/Server/CargoLoad.lua` | Roped crate, per-strap tension and health, derived condition |
| `src/Server/StrapperStations.lua` | Station occupancy, committed traversals, counterweight, throws |
| `src/Server/PressureDirector.lua` | Three pressure categories that perturb state, never outcomes |

### Depot build

| Module | Responsibility |
|---|---|
| `src/Server/EconomyService.lua` | Sole authority for payouts, streaks, purchases |
| `src/Server/WorldBuilder.lua` | Depot hub, board, four parallel lanes |
| `src/Server/DepotService.lua` | Bays, membership, spectating, remotes, depot snapshot |
| `src/Server/CrewMatch.lua` | One crew's phase machine and leg ladder |
| `src/Server/CargoRig.lua` | One crew's truck |
| `src/Server/FailureRunner.lua` | One crew's failure cadence |
| `src/Server/RoleService.lua` | One crew's role assignment and kit effects |

## Tests

Two suites, split by whether they need Roblox running. `lune run Tests/Headless.luau`
covers config invariants, route maths, bucket arithmetic and the tuning schema
in a couple of seconds, and CI runs it on every push. The engine-dependent half
is `require(game.ServerStorage.Tests.StudioSmoke).run()` from the Studio command
bar after pressing Play. [Tests/README.md](Tests/README.md) has the split and
which suite a new test belongs in.

## Out of scope (v0)

Trading, gacha pulls, open world, seasons, voice-only puzzles, paid power. See the declined-patterns
list in [Docs/TopGameDNA_V0.md](Docs/TopGameDNA_V0.md) for why.
