# Vertical Slice — Cargo Run V0

Build target for the first playable. One map segment, one vehicle, one cargo type. No progression beyond win/fail.

## Fantasy in one screenshot

A beat-up flatbed truck, one oversized orange crate strapped to the bed, a short cliffside road, and four role labels. If the crate is tipping, the screenshot already sells the game.

## Environment

| Element | Spec |
|---|---|
| Map | Curved graybox road ~260 studs with Start + Delivery zones |
| Hazards | Marked sharp bend, off-road cargo damage, final stop-in-zone delivery |
| Vehicle | Single server-driven arcade cargo truck (`CargoTruck`) with keyboard and touch input |
| Cargo | One crate with states: **Stable**, **Tipping**, **Dumped** |
| Lighting | Readable daylight; failures use color + banner, not subtle VFX |

## Roles in the slice

| # Players | Roles live |
|---|---|
| 1 | Driver (solo stub; resolve prompts still testable via Action button) |
| 2 | Driver + Strapper |
| 3 | Driver + Strapper + Spotter |
| 4 | Driver + Strapper + Spotter + Repair |

All role jobs must be understandable from HUD text alone (chat optional).

## Session contract

```
Lobby → Starting (3s) → Run (~120s prototype / 8–12 min ship) → Resolve → Rematch
```

- **Win:** truck reaches and stops in the delivery zone with cargo stability > 0
- **Fail:** cargo stability hits 0, or cascade severity accumulates past dump threshold (prototype: 3)

## Failure deck (v0 data)

Defined in `src/Shared/Failures.lua`:

1. Loose Strap — Strapper
2. Sharp Turn — Driver
3. Engine Fault — Repair
4. Wheel Wobble — Repair
5. Cargo Tilt — Strapper
6. Ramp Drop — Repair
7. Blind Corner — Spotter
8. Overheat — Repair

Each failure:

- Has a short response window
- Uses a role-specific interaction: Driver braking, Spotter pinging, or Strapper/Repair holding an action
- Cascades if ignored (stability loss + tipping/dump read)
- Has a one-line clip sentence (e.g. “He didn’t strap it.”)

The opening scenario is route-driven rather than random: Blind Corner → unsafe Sharp Turn → Loose Strap recovery. Later random events are filtered to roles present in the current party.

## Clip moments to manufacture every run

At least one of:

- Near-save strap at the last second
- Full dump over the edge / off the bed
- Ignored Spotter ping → wipe
- Wrong timing on a turn while cargo is tipping

If a run can finish with zero dramatic event, the failure interval tuning is wrong.

## Recovery rules

- Not every mistake is instant fail
- Early cascades tip the cargo; repeated cascades dump it
- Successful resolve nudges stability up slightly and resets crate to Stable

## Explicitly not in this slice

- Multiple cargo types
- Multiple truck classes
- Persistent unlocks / XP
- AI traffic / NPCs
- Physics suspension tuning beyond readable tipping
- Monetization

## Acceptance

Matches [BuildChecklist_V0.md](BuildChecklist_V0.md): party can start, get a failure, save or dump, see resolve, rematch — without using the command bar.

## Code map

| Concern | Path |
|---|---|
| Config | `src/Shared/MatchConfig.lua` |
| Roles | `src/Shared/Roles.lua` |
| Failure defs | `src/Shared/Failures.lua` |
| Cargo manifest | `src/Shared/CargoManifest.lua` |
| Depot, bays, remotes | `src/Server/DepotService.lua` |
| Per-crew match flow | `src/Server/CrewMatch.lua` |
| Failure runtime | `src/Server/FailureRunner.lua` |
| Truck/cargo stub | `src/Server/CargoRig.lua` |
| Crew HUD | `src/Client/MatchUI.lua` |
| Depot panel | `src/Client/DepotUI.lua` |
