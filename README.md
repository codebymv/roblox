# Roblox · Co-op Cargo Catastrophe

Prototype project for a **Co-op Operational Catastrophe** experience on Roblox:

> A crew of up to four shares one truck. One drives; the rest work the straps holding a real crate onto a real bed. After every delivery the crew votes on the next contract: a plain haul, or Catastrophe pressure for more pay. One bad strap, turn or corner cascades into a readable disaster.

This folder is intentionally separate from the UE5 PlatypunkGame repo.

## One build

There used to be two. `Depot` was the original prototype -- four bays, a leg
ladder, bank-or-push, role kits, live-ops -- and
[Docs/CoreFunAudit_V0.md](Docs/CoreFunAudit_V0.md) found that its truck was an
anchored, non-collidable model repositioned by `PivotTo`, that cargo condition
was a single scalar the visuals obeyed rather than reported, and that only the
Driver had continuous input.

The physics-first rebuild replaced it and the depot was kept dormant behind a
mode switch for a while afterwards. It has now been deleted: about 4,200 lines
across thirteen modules that never booted, but were still paid for on every
format, lint, type check and refactor. Its crew-vote phase machine was
harvested first and is what the contract board runs on.

Tooling profiles remain. Studio automatically uses `Development` (debug overlay,
live tuning, commands, and run artifacts), while published servers use a
fail-closed `Release` profile with only server telemetry left on. The place is
capped to one four-player crew.

## Structure

```
roblox/
  README.md
  Docs/                     Design intent; Docs/README.md says what is still current
  src/Shared/               Config, types, tuning schema, manifests, kits, networking
  src/Server/               Session, physics truck, cargo, telemetry, commerce, profiles
  src/Client/               UI kit, HUD, contract board, audio buses, particles, overlay
  Tests/                    Headless suite (Lune, in CI) and Studio smoke test
  rokit.toml                Pinned toolchain
  default.project.json      Rojo project map
```

## Docs

Start with [Docs/README.md](Docs/README.md), which sorts the eight design
documents by whether they still describe the build, then read
[Docs/PlaytestProtocol_V0.md](Docs/PlaytestProtocol_V0.md), which is the next
thing that happens to the project. [Docs/CoreFunAudit_V0.md](Docs/CoreFunAudit_V0.md)
is historical: it explains why the original Depot prototype was replaced, not
how the current fun-test behaves.

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

## The loop

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

Published servers keep those raw artifacts disabled. Instead, the Release
profile sends a compact run summary through Roblox Analytics: outcome, route
progress, final cargo and chassis condition, meaningful crew actions, resets,
simulation errors, and aggregate client-to-server drive-input age. It contains
no player names or raw input history and can be broken down by outcome, crew
size, and run variant in the Creator Dashboard.

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
| `src/Server/LabTelemetry.lua` | Studio run timeline/artifact plus the anonymous compact run summary |
| `src/Server/LabAnalytics.lua` | Published-server onboarding funnel, run summaries, session metrics, and structured feedback |
| `src/Server/PlayerDataService.lua` | Shared DataStore profile cache, autosave, volatile fallback, and `BindToClose` |
| `src/Shared/LabProgression.lua`, `src/Server/LabProgressionService.lua` | Testable run rewards plus the persistent Cargo Cash and paint adapter |
| `src/Shared/TokenBucket.lua`, `src/Server/RateLimiter.lua` | Throttling, split into engine-free maths and a Player-keyed wrapper |
| `src/Shared/RouteMath.lua` | Arc-length progress and its inverse, dependency-free |
| `src/Client/UIKit.lua` | Panels, labels and buttons, plus setters that skip unchanged writes |

### The game

| Module | Responsibility |
|---|---|
| `src/Server/TruckLab.lua` | Composition root: builds the route, owns one `LabSession`, wires dev commands |
| `src/Server/PhysicsChassis.lua` | Raycast-suspension truck, grip, steering, impact and rollover |
| `src/Server/CargoLoad.lua` | Roped crate, per-strap tension and health, derived condition |
| `src/Server/StrapperStations.lua` | Station occupancy, committed traversals, counterweight, throws |
| `src/Server/PressureDirector.lua` | Three pressure categories that perturb state, never outcomes |

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
