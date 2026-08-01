# Core Fun Audit v0

> **Historical diagnosis, not a description of the current build.** This audit
> was written against the retired Depot runtime before the physics-first
> `FunTest` rebuild. Its findings explain why that rebuild happened; claims
> about solo play, role activity, cargo physics, and the active session loop
> should not be used to assess the current game. For current behaviour, start
> with the root [README](../README.md) and [PlaytestProtocol_V0.md](PlaytestProtocol_V0.md).

Written before any code changed, against commit state of `main` at the time of the
Core-Fun Recovery pass. The purpose is to answer one question honestly:

> Is the current build capable of producing the experience "operating an unstable
> cargo vehicle together"?

The answer is no, and this document records exactly why, so the milestones that
follow can be judged against evidence rather than opinion.

---

## 1. The traced gameplay path

```
Player joins
  -> DepotService.onPlayerAdded            (auto-crew into best joinable bay)
  -> CrewMatch:addMember                   (phase Idle -> Staging)
  -> CrewMatch:_beginStageTimer            (solo 5s / crew 14s auto-depart)
  -> CrewMatch:_beginDeparture             (3s countdown)
  -> CrewMatch:_startConvoy                (RoleService:assignForPlayers, paint)
  -> CrewMatch:_startLeg                   (roll cargo, set timer/pressure)
  -> CrewMatch:_runLeg                     (task.spawn, task.wait(0.05) loop)
       -> CargoRig:step                    (integrate position, PivotTo)
       -> FailureRunner                    (schedule + expire authored failures)
       -> progress gates                   (tutorial strap, blind corner, sharp turn)
  -> CrewMatch:_deliverLeg                 (phase BankOrPush)
  -> vote -> _bank / _push
  -> _wipe or Resolve -> requestNewConvoy
```

Everything in that chain works. The problem is not correctness; it is that the
chain contains no physical simulation at any point.

## 2. Interaction classification

Every interaction in the run, sorted by what it actually is.

### Physical (real Roblox physics)

One, and it is a failure state rather than gameplay:

```242:251:src/Server/CargoRig.lua
	if state == "Dumped" then
		if crate.Parent == model then
			local worldCFrame = crate.CFrame
			crate.Parent = self.lane.folder
			crate.CFrame = worldCFrame
			crate.CanCollide = true
			crate.Anchored = false
			crate.AssemblyLinearVelocity = body.CFrame.RightVector * 34 + Vector3.new(0, 12, 0)
```

The crate becomes a real object only at the moment the run is already lost.

### Visual simulation (looks physical, is not)

The truck. Every part is anchored, `CanCollide = false`, and the model is
repositioned wholesale each tick:

```227:231:src/Server/CargoRig.lua
function CargoRig:_pivot()
	if self.model and self.model.PrimaryPart then
		self.model:PivotTo(CFrame.new(self.position) * CFrame.Angles(0, self.heading, 0))
	end
end
```

There is no mass, no momentum, no suspension, no lean, no weight transfer, and
no collision. Consequences that matter for the design:

- The truck cannot roll over, because it has no orientation beyond yaw.
- Nobody can stand on it, because nothing on it is collidable.
- Braking and turning cannot trade against each other, because neither one
  affects anything except a speed scalar and a heading scalar.
- The road cannot constrain the truck. `offRoad` is a lateral distance test
  against an analytic centerline, so the road geometry is scenery.

The cargo tilt is likewise a pose, not a simulation:

```264:266:src/Server/CargoRig.lua
	crate.CFrame = body.CFrame
		* CFrame.new(0, 5.5, -3)
		* CFrame.Angles(0, 0, if state == "Tipping" then math.rad(23) else 0)
```

Twenty-three degrees, always, regardless of speed, turn severity, or cargo mass.

### Numerical only

`cargoStability`, a 0-100 scalar, is the actual subject of the game. Every
change to it is a constant:

| Source | Magnitude |
| --- | --- |
| Cascade (generic) | `-cascadeSeverity * 20` |
| Cascade (SharpTurn) | `-15` |
| Cascade (BlindCorner) | `-8` |
| Failure resolved | `+5` |
| Off-road above speed 4 | `-7/sec` |
| Passive recovery while Tipping | `+3/sec` |

The crate's appearance is downstream of this number. Cause and effect run
backwards: the meter decides, and the world illustrates.

`truckIntegrity` is a second scalar with the same shape, changed only in fixed
steps of `TruckDamagePerCascade = 22` and `RepairIntegrityRestore = 18`.

### Timer and prompt based

The entire failure system. A failure fires, a window opens, the responsible role
holds a button, and `task.delay` decides the outcome:

```126:137:src/Server/FailureRunner.lua
	task.delay(window, function()
		-- ...
		current.cascaded = true
		self.cascadeCount += def.cascadeSeverity
		self._callbacks.onCascade(def)
```

Eight authored failures, each with a predetermined severity. The director does
not create pressure; it announces outcomes and gives a grace period.

## 3. Per-role action density

Measured as: does the role send input when no prompt is on screen?

| Role | Continuous input | What it actually does | Idle share of a leg |
| --- | --- | --- | --- |
| Driver | Yes, `Heartbeat` at 10 Hz | Throttle, steer, brake | Near zero |
| Strapper | No | Holds a button when `responsibleRole == "Strapper"` (2 of 8 failures) | Very high |
| Spotter | No | Clicks Ping when BlindCorner fires (1 of 8 failures) | Extremely high |
| Repair | No | Holds a button on 4 of 8 failures | High |

The gate is explicit:

```1102:1106:src/Server/CrewMatch.lua
	if not roleId
		or not active
		or active.resolved
		or active.cascaded
		or active.def.responsibleRole ~= roleId
	then
		return
```

No prompt naming you means no possible action. With `FailureMinIntervalSeconds = 12`
to `FailureMaxIntervalSeconds = 22` and a single active failure at a time, a
four-player crew has three players doing nothing for most of every leg. The
server states the design out loud at convoy start:

```513:513:src/Server/CrewMatch.lua
	self:_toast("Roles assigned. Driver has WASD; everyone else watches the load.")
```

## 4. Which outcomes can vary

| Outcome | Varies naturally? |
| --- | --- |
| Cargo damage from a cascade | No, fixed per failure id |
| Whether a failure cascades | Only via a binary hold-in-time check |
| Where the cargo ends up | No, one canned tilt pose or one canned launch impulse |
| Truck damage | No, fixed 22 per damaging cascade |
| Route difficulty | No, geometry is flat and never touched by the sim |
| Run length | Only by leg number, via a duration curve |

Two runs with the same button timings produce identical results. There is no
state that carries forward within a leg other than two meters and a cascade
counter, so there is nothing for a second crisis to emerge from.

## 5. Which systems are essential to a fun test, and which are not

Essential and currently missing:

- A truck with mass, momentum, suspension, and the ability to roll.
- Cargo as a real object whose position on the bed is the game state.
- Straps as individually addressable objects that can be under tension, weaken,
  break, and be re-secured.
- Route geometry that actually constrains the vehicle.
- A non-driver role with continuous spatial work.

Present, working, and irrelevant to the question being tested:

`PlayerDataService`, `EconomyService`, `CargoManifest` rarity and journal,
`RoleKits`, `LiveOps`, `DepotService` multi-bay routing, `DepotUI` shop and
leaderboards, `Nameplates`, bank-or-push, credits, daily bonus, convoy streak.

None of these are deleted. All of them are bypassed by `DevConfig.Mode`.

## 6. What the fun-test build bypasses

| System | Status in `FunTest` mode |
| --- | --- |
| `DepotService` (4 bays, routing, spectate) | Not initialised |
| `PlayerDataService` | Not initialised, no DataStore traffic |
| `EconomyService`, credits, payouts | Bypassed |
| `RoleKits`, paints, shop | Bypassed |
| `LiveOps` weekly modifiers | Bypassed |
| `CargoManifest` rarity roll and journal | Bypassed, one fixed crate |
| Bank-or-push, leg ladder, convoy streak | Bypassed, one route |
| `DepotUI`, `Nameplates` | Not mounted |
| `MatchUI` | Not mounted, replaced by `LabUI` |
| Authored 8-failure deck | Replaced by a 3-category pressure director |

## 7. Technical constraints that shaped the redesign

1. **Server-applied forces require server network ownership.** The chassis is
   simulated with `ApplyImpulseAtPosition` on the server every `Heartbeat`, so
   the assembly is pinned to `SetNetworkOwner(nil)`. The driver therefore pays
   one round trip of input latency. This was accepted over granting the driver
   ownership, because client ownership would let client-side physics overwrite
   server forces and would desynchronise the cargo for every other player.

2. **Humanoids do not walk reliably on fast-moving platforms.** Free-walking the
   bed of a truck at 28 studs/s produces jitter and unintended ejections. The
   Strapper is therefore seated on a `Weld` whose `C0` is interpolated between
   station offsets, which carries the player perfectly and still preserves the
   spatial choice, the traversal commitment, and the risk of being caught out of
   position. Free-walking remains a stretch goal.

3. **Rope constraints are the stable way to model straps.** `RopeConstraint`
   resists extension only, which is exactly strap behaviour, and it degrades
   gracefully when one is removed. Spring or weld based straps either fight the
   solver or fail all-or-nothing.

4. **Constraint tension is not directly readable.** Roblox does not expose the
   force in a `RopeConstraint`, so per-strap tension is computed from measured
   chassis acceleration, crate mass, and rope geometry. It is an estimate, but it
   is derived from real simulated quantities rather than authored.

## 8. Defects found during the audit

Both are real but neither blocks the fun test, so they are fixed in an isolated
commit.

**Paint equip silently spends credits.** `DepotService.handleEquip` routes
`kind == "Paint"` to `EconomyService.purchasePaint`, which unlocks and deducts
when the paint is unowned. Kits split purchase from equip correctly and
`equipKit` rejects unowned kits; paint has no equivalent equip-only path, so the
client's "equip" button is a purchase button for anything not yet owned.

**No rate limiting on `RoleAction` or `DriveInput`.** Both bind straight through
`DepotService` with only shape and role validation. `handleRoleAction` spawns a
`task.delay` per accepted call, so a spamming client can queue unbounded timers.
