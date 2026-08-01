# Playtest Protocol v0

The fun-test build exists to answer one question:

> Is operating an unstable cargo vehicle together intrinsically funny, tense,
> readable, and replayable?

Everything below is designed to get an honest answer to that first. The public
build now awards a shallow layer of Cargo Cash and truck paint, but the reward
appears only after the run. Observe the decision to finish and replay before
mentioning the garage so progression does not masquerade as core fun.

---

## Before the session

1. `DevConfig.Mode` is `"FunTest"`. Confirm the server log prints
   `[CargoLab] Fun-test mode running (Release)` in a published server.
2. Build profiles are automatic. Studio uses `Development`; every published
   server uses `Release`, which disables the debug overlay, live tuning,
   developer commands, verbose physics, and Studio-only run artifacts. Server
   startup fails closed if a future change makes that profile unsafe. Roblox
   Beta Mode is a dashboard distribution setting, not a third code profile;
   published beta servers use this same `Release` profile.
3. The place and server crew caps both remain `4`: one Driver and three
   Strappers. Roblox rejects a fifth join; the in-session spectator queue is a
   defensive fallback for oversized Studio tests and failed seat attachment.
4. Release telemetry remains on.
5. Where you read the log depends on how they are joining. In a Studio local
   server it is the output window, on your own screen and not theirs. On a
   published place it is the developer console, `F9`, Server tab, which only
   the place owner can see. Development run artifacts land in
   `ServerStorage.LabRuns`; published servers intentionally do not create them.

Tuning between sessions requires no flag editing: start a Studio session for
the Development profile, then publish when ready. To rehearse Release inside
Studio, temporarily set `FORCE_PROFILE` in `DevConfig.lua` to `"Release"`.

## Roles for the session

Four players. One drives, three work the bed. Anyone can press `T` to hand over
or take the wheel between runs, and you want them to, because "would you choose
a non-driver role?" is one of the questions being tested.

Use Roblox platform chat/voice or a shared Discord call for facilitated tests.
Do not add a bespoke communication system before observing whether platform
communication and the game's physical tells are insufficient.

With two or more crew, the red `SWAP` signs force a deterministic rotation.
Do not explain the order before the first run. Observe whether the personalized
warning is enough for the incoming Driver to take over without being coached.

## The script

Say exactly this and nothing more:

> You are a crew delivering one crate. One of you drives. The rest of you are on
> the back keeping the load on the truck. Number keys move you around the bed,
> hold E to work on the strap you are standing at. Go.

### What not to explain

- Do not explain strap health, tension, or the condition ladder.
- Do not explain that a strap starts weakened.
- Do not explain the corner, the descent, the rough section, or the bridge.
- Do not explain that standing on one side counterbalances the truck.
- Do not tell the driver a safe speed.
- Do not tell them what the HUD numbers mean.
- Do not warn them a strap is about to fail.
- Do not tell them a broken strap can be refitted.

If they ask a rules question mid-run, say "find out" and note that they asked.
A question you have to answer is a readability failure worth recording.

## What to observe

Watch the players, not the screen.

| Signal | What it tells you |
| --- | --- |
| Do they look at the truck or the HUD? | Whether the physical feedback is carrying the meaning |
| Do they talk without being prompted? | Whether the roles actually depend on each other |
| Does anyone say "slow down" or "get to the left"? | Whether the state is legible enough to give orders about |
| Does the driver react to what the load is doing? | Whether the two systems feel connected |
| Does anyone laugh or swear? | The clip test, live |
| Who is idle, and for how long? | Whether the supporting role is real |
| Do they start a second run without being asked? | The only retention signal that counts here |

## Events that should occur

If a run does not produce most of these, the build is not doing its job.

1. The load visibly shifts on the blind corner in the first 90 seconds.
2. At least one strap breaks during a session.
3. Someone crosses the bed while the truck is moving.
4. Someone gets thrown off, or comes close enough to notice the risk.
5. The truck's handling visibly changes after the load moves.
6. At least one crisis is recovered rather than lost.
7. At least one run ends differently from the run before it.
8. Both SWAP gates rotate every active crew member without duplicate stations,
   stuck controls, or a coaching prompt from the facilitator.

## Reading the telemetry

The server log prints a block per run. The lines that matter:

| Line | Healthy value | What a bad value means |
| --- | --- | --- |
| `time to movement` | under 10s | The start is too slow |
| `time to crisis` | 45-100s | Too early is unfair, too late is boring |
| `cargo transitions` | 6 or more | The load is not doing enough |
| `recoveries` | 1 or more | Failures are binary, not recoverable |
| `station moves` | 4 or more per crew member | The Strapper is passive |
| `crew swaps` | 2 on a complete 2+ player run | A gate was skipped or failed |
| `drive input age` | Record the baseline beside any handling complaint | Separates network delay from truck or road tuning; inspect the >=200ms tail |
| `idle` per crew member | under 25% of run | That role is not a role |
| `designed cascade` | true | The opener is not landing |
| `emergent cascade` | true on most runs | Systems are not interacting |

A run where `station moves` is near zero and only the driver has actions is the
single clearest no-go signal in the whole document.

### Published analytics

Published servers also send aggregated Roblox analytics; Studio deliberately
does not. The onboarding funnel is `Joined Game` → `Crew Seat Assigned` →
`First Crew Input` → `First Run Finished` → `Second Run Started`. Custom events
record crew size, time to first input and crisis, outcomes, run and session
duration, SWAP gates, mid-run departures, and the once-per-session
`Yes`/`Maybe`/`No` replay answer. Each finished run also emits a compact summary:
progress, cargo and chassis condition, breaks/refits, recoveries, throws, swaps,
manual resets, simulation errors, and aggregate client-to-server drive-input
age. Outcome, crew size, and run variant are attached as breakdown fields. No
player names, raw timeline, or high-frequency input stream leaves the server.
Roblox aggregates these events daily, so allow up to 24 hours before treating an
empty dashboard as a wiring failure.

### Progression smoke test

Every active crew member receives the full server-calculated reward; bringing
friends never splits the payout. A clean delivery pays more than a partial
delivery, and a recoverable failure still grants a small participation amount.
On the result screen confirm the reward and new balance agree, then during
Result or Staging unlock a paint in the garage. The Driver's equipped paint
should recolor the cab and fenders for the shared truck.

For Studio persistence tests, enable **Game Settings -> Security -> Enable
Studio Access to API Services**. When it is disabled, the HUD explicitly says
`NOT SAVING`; published servers use DataStoreService normally. Studio has its
own test store and cannot overwrite live balances. Stop and start a fresh
Studio session after an unlock to verify the balance and paint return.

## Questions to ask afterwards

Ask these in order, and write the first sentence of each answer verbatim.

1. What happened in that run? (You are testing whether they can narrate it. If
   they cannot, a clip of it will not read either.)
2. Whose fault was it?
3. What would you do differently next time?
4. Which job would you pick if you played again?
5. Was there a moment you thought you had lost it and then did not?
6. Did anything feel unfair or random?
7. Would you play another run right now?

Question 4 is the one to weight most heavily. If every answer is "driver", the
supporting role has failed regardless of how good the physics feel.

## Strong signal

- They narrate the run to each other unprompted, in physical terms
  ("the front-left let go", not "stability dropped").
- They assign blame, and the blame is accurate.
- Someone volunteers for a non-driver role on the next run.
- They ask for one more run before you offer it.
- Two runs on the same road produce visibly different stories.
- They invent tactics you did not design, such as pre-positioning on the outside
  of a corner before it arrives.

## Failure signal

- The driver is the only person talking.
- Crew members sit at one station the whole run.
- They read the strap panel instead of looking at the load.
- Losses feel arbitrary to them, and they cannot say what caused one.
- They ask what the numbers mean.
- Runs resolve identically.
- Nobody asks for another run.

## Go / no-go

Continue building on this direction only if, across at least four sessions:

- The driver enjoys the run before seeing its progression reward.
- At least one non-driver role is chosen voluntarily.
- Cause and effect are visible without the HUD.
- Similar conditions produce different outcomes.
- Disasters are recoverable often enough to be worth attempting.
- Players restart without being prompted.
- A 15-second clip reads to someone who was not in the room.

Redesign or pivot if:

- Only the driver is engaged.
- The supporting roles have collapsed back into "press the button when told".
- Cargo loss is only legible as a number.
- Failures read as random.
- Clips need captions.
- Repeated runs resolve identically.
- Players do not talk to each other.

## The clip test

One 10-15 second clip should come out of the blind corner. Expected shape:

- **Setup.** The truck comes down the warm-up straight carrying too much speed.
  The crate is already sitting slightly off-centre, because the front-right
  strap went on tired and has been stretching since the start.
- **The mistake.** The driver commits to the blind right-hander without braking.
- **The escalation.** Weight transfers onto the outside wheels, the inside front
  goes light, the crate slides toward the left rail and the remaining straps go
  visibly taut. One of them snaps.
- **The attempted recovery.** A crew member commits to crossing the bed to reach
  the failing corner. Mid-traversal the truck lurches and they are thrown off
  the side, tumbling down the road behind the truck.
- **The resolutions.** Any of: the second strapper reaches the anchor and holds
  it; the crate hangs off the side and drags, hauling the truck toward the
  shoulder; the crate goes over entirely and bounces down the road; the whole
  truck rolls.

A stranger should be able to follow that with the sound off and the HUD cropped,
because every beat is a physical object doing a visible thing: a truck leaning,
a strap snapping, a crate sliding, a person falling off. If a viewer needs a
caption to know what went wrong, the physical feedback is not finished.
