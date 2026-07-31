# Prototype Brief — Cargo Catastrophe V0

## One-sentence pitch

3–4 friends jointly haul unstable cargo through a short hazard route; one bad strap, turn, or repair cascades into a clip-readable disaster; win or fail in about 8–12 minutes.

## Target player

- Friend groups roughly ages 13–18
- Mobile-first controls; simple taps/holds, not precision PC parkour
- Party of 3–4 is the real unit of play; solo must boot for Studio testing but should feel incomplete

## Core player fantasy

“We are a chaotic delivery crew keeping one valuable load alive against physics and each other.”

## Core verb

**Stabilize** — strap, steer, spot, and repair under pressure so the cargo does not dump.

## Thirty-second player loop

1. See a threat (loose strap, sharp turn, engine smoke, cargo tilt).
2. Role does their job (or fails / does the wrong thing).
3. Cargo stabilizes — or a cascade starts that everyone can read in two seconds.

## Full session structure

| Phase | Duration | What happens |
|---|---|---|
| Lobby | ~30–60s | Join party, pick or auto-assign roles, Start |
| Run | ~8–12 min | Drive route, failure deck fires, recover or cascade |
| Resolve | ~10–20s | Win (cargo delivered) or Fail (cargo lost / wreck) |
| Rematch | immediate | Same party continues with one button |

Persistent or round-based: **round-based runs** (no multi-day meta in v0).

## Roles (visually obvious; no chat required)

| Role | Job | Primary input | Visible tell |
|---|---|---|---|
| Driver | Steer, brake, pace turns | Drive vehicle | Wheel / seat highlight |
| Strapper | Re-secure loose cargo | Hold / mash strap prompt on cargo | Rope / latch VFX |
| Spotter | Call hazards early (UI pings + markers) | Mark hazard ahead | Binoculars / ping icons everyone sees |
| Repair | Fix engine / wheel / ramp faults | Interact at fault point | Wrench / spark clear |

With 2 players: Driver + Strapper (Spotter/Repair auto-simplified or AI-light prompts).  
With 3: add Spotter.  
With 4: full crew.  
Solo stub: Driver only; failures auto-announce and offer simplified recover prompts for testing.

## Primary clip moment

Cargo dump / near-save / cascade fail — “he didn’t strap it” / “we had one second left” / “the whole load went over.”

Secondary clips: wrong repair, last-second latch, Spotter ping ignored then wipe.

## Procedural failure deck (design target)

~8–12 event types in data; a run samples a subset so sessions differ. See [VerticalSlice_CargoRun_V0.md](VerticalSlice_CargoRun_V0.md) for the v0 list.

## What the player gains / loses

- **Gain:** successful delivery, bragging rights for the run, funny fail clips
- **Lose:** the cargo (run fail) — temporary; no persistent inventory loss in v0

## Monetization hypothesis (not built in v0)

Cosmetics for roles / vehicle skins / cargo skins; convenience QoL later. No P2W that breaks trust in co-op failure attribution.

## Explicitly excluded from v0

- Economy, Robux shop, gacha, trading
- Seasons / battle pass
- Open world
- Voice-dependent puzzles
- Heavy cosmetics pipeline
- Long narrative / campaign
- UGC building tools

## Kill criteria

Abandon or pivot if:

- First-minute abandon regularly exceeds ~45%
- Fewer than ~25% of sessions produce a cascade / near-cascade fail
- Players prefer solo or idle over party play
- Screen recordings need lore explanation to be funny

## Success criteria (go deeper)

- Same-session replay rate above ~40%
- Friend invite or party continue in first session above ~15%
- Strangers understand a clip without knowing the game
- Failures feel caused by player decisions, not pure RNG spite

## Smallest viable prototype

One truck, one cargo crate, one short route, 3–4 roles, failure deck runner, win/fail UI, rematch. Fake physics OK if the **read** of failure is clear.
