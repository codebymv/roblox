# Systems Reuse Map V0

> **Superseded. Historical only.**
>
> Every phase, enum and file listed below belongs to the depot build, which
> `DevConfig.Mode` no longer selects by default. The fun-test build has its own
> much shorter lifecycle (`Staging → Run → Result`) owned by
> `src/Server/LabSession.lua`, and its own remotes in `src/Shared/LabRemotes.lua`.
> The file-ownership table at the bottom predates `LabSession`, `TuningService`,
> `DevCommands`, `UIKit` and `TokenBucket` and should not be used to find
> anything.
>
> The "Never port" section is the part still worth reading, and the adopt /
> adapt / skip framing is a good template if a second title reuses this spine.

Cross-repo contracts adopted into Cargo Catastrophe as **Luau reimplementations**.  
Rule: steal ownership rules, state machines, fail enums, HUD shapes · never port UE / Three.js / FlashCore engines.

## Standardized enums (Roblox)

### CrewPhase

One instance per bay. `CrewMatch` is the sole writer of its own phase.

`Idle → Staging → Departing → Run → DeliveryHold → BankOrPush → (Run leg+1 | Resolve) → Staging`

| Phase | Notes |
|---|---|
| Idle | Bay empty; no simulation |
| Staging | Crew forming; auto-departs on a timer, Ready only shortens it |
| Departing | Short countdown, roles assigned at the end |
| Run | Failures + drive for the current leg |
| DeliveryHold | Final route segment; higher pressure, shorter windows |
| BankOrPush | Twelve-second crew vote; majority rules, tie or timeout banks |
| Resolve | Endcard, then back to Staging |

### FailReason

| Value | Meaning |
|---|---|
| `Banked` | Crew banked the stack and ended the convoy |
| `Delivered` | A single leg completed (interim, drives the BankOrPush card) |
| `CargoDumped` | Cargo stability / cascade dump; forfeits the stack |
| `TruckTotaled` | Truck integrity hit zero; forfeits the stack |
| `TimeExpired` | Leg clock hit zero before delivery |
| `CrewLeft` | Crew member left mid-convoy |

## Adopt / adapt / skip

| System | Source | Roblox target | Status |
|---|---|---|---|
| Sole phase authority | Platypunk `RunSliceV1` / RunGameMode | `src/Server/CrewMatch.lua`, one per bay | **Adopt** |
| Physical lobby ready + countdown | Platypunk LaunchTerminal; FlashCore `multiplayerRooms.js` | Bay pads you stand on, plus `Staging` / `Departing` | **Adopt** |
| Carried vs banked haul | Platypunk drip / extract | `carriedValue` across legs, only paid on Bank | **Adopt** (now the spine) |
| Clock × stage pressure | Platypunk stage volumes; fps-mvp director | FailureRunner pressure × leg number × route progress | **Adopt** |
| One HUD snapshot + endcard | Platypunk HUD; fps-mvp HudController | `Types.CrewSnapshot` + `MatchUI.lua` | **Adopt** |
| Contract phases + world cues | fps-mvp `contracts.ts` / `LoopWorldCues` | DeliveryHold + delivery zone cue | **Adopt** |
| Extract hold ramp | fps-mvp extract hold→heavy→final | DeliveryHold shorter windows | **Adapt** |
| Room ready/countdown/finish/rematch | FlashCore `multiplayerRooms.js` | Four bays with join / leave / spectate | **Adapt** (no WS rooms) |
| Vehicle damage → repair → totalled | Freeway Escape `damage.js` | TruckIntegrity vs CargoStability | **Adopt** |
| Driving feel under stress | Freeway `drivingPhysics.js` | `CargoRig:step` feel targets | **Skip code** (keep arcade stub) |
| Hireable repair composition | Barricade Watch roles | Existing Repair role | **Adapt** (player role, not NPC hire) |
| Between-run risk board | fps-mvp ContractOffer | `BankOrPush` vote after every leg | **Adopt** |
| Garage / meta unlocks | Freeway garage | `RoleKits` + cab paint bought with credits | **Adopt** |
| Profile persistence | Platypunk GameInstance | `src/Server/PlayerDataService.lua` | **Adopt** (ProfileService if this ships) |
| BUILD → CHAOS phases | Papercraft Armada | Deferred (secure-then-drive) | **Skip v0** |

## Never port

- Platypunk: Souls combat, poise, flask, lock-on, AccuRIG, World Partition city, SpringArm
- fps-mvp: custom colliders, parkour, client-authoritative solo loop, VS PvP relay/msgpack, debt fiction
- FlashCore: Stripe/auth/iframe portal, 1v1 duel items as core loop, Matter.js / Three.js engines
- Any shared npm/UE plugin used as a gameplay “engine”

## File ownership

| Concern | Module |
|---|---|
| Profiles and saving | `src/Server/PlayerDataService.lua` |
| Credits, payout curve, purchases | `src/Server/EconomyService.lua` |
| Depot, bays, spectating, remotes | `src/Server/DepotService.lua` |
| Per-crew phase, legs, bank/push | `src/Server/CrewMatch.lua` |
| Truck integrity / delivery cue | `src/Server/CargoRig.lua` |
| Hub and lane geometry | `src/Server/WorldBuilder.lua` |
| Failure pressure / windows | `src/Server/FailureRunner.lua` |
| Roles and kit effects | `src/Server/RoleService.lua` |
| Shared types / config | `src/Shared/Types.lua`, `MatchConfig.lua` |
| Cargo, kits, events | `src/Shared/CargoManifest.lua`, `RoleKits.lua`, `LiveOps.lua` |
| Remotes | `src/Shared/Net.lua` |
| Crew HUD / endcard | `src/Client/MatchUI.lua` |
| Depot panel and standings | `src/Client/DepotUI.lua` |
