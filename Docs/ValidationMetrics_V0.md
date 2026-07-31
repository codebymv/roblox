# Validation Metrics — Cargo Catastrophe V0

Measure only what tests the central hypothesis:

> Friend-group co-op + readable cascading failure produces replay and invites without economy or content farms.

## Instrumentation (manual OK for first playtests)

Track per session / per playtester batch. Spreadsheet is fine until analytics exist.

| Metric | How to collect | Why it matters |
|---|---|---|
| Thumbnail / first-look interest | Ask: “Would you tap this?” (optional) | Discovery readability |
| Tutorial / lobby completion | Started run / entered lobby | Onboarding friction |
| First-minute abandon | Left before 60s of run | Hook failure |
| First-session duration | Total minutes in place | Engagement |
| Round completion | Reached win or fail screen | Loop clarity |
| Immediate replay rate | Rematch or new run within same session | Fun density |
| Friend invite rate | Invited someone during first session | Social acquisition |
| Party continuation rate | Same party starts another run | Group retention signal |
| Cascade event rate | % sessions with at least one cascade / near-dump | Clip engine firing |
| Share / clip intent | “Would you send this clip to a friend?” | Viral potential |
| Clip readability | Blind viewer describes clip in one sentence | Two-second rule |

## Ladder and retention metrics

Added once the depot build shipped. These test the second hypothesis: that a persistent profile and
a push-your-luck ladder give players a reason to come back tomorrow, which the original binary run
did not.

| Metric | How to collect | Why it matters |
|---|---|---|
| D1 / D7 return rate | Distinct returning users over distinct new users | The single strongest discovery input; Roblox now scores D1, D2-7, and D8-28 separately over a 28-day window |
| Time from spawn to first drive input | Log the first `DriveInput` per session | The sub-10-second promise either holds or it does not |
| Average legs per convoy | Log leg count at every convoy resolve | The shape of the ladder |
| Bank-vs-push ratio | Count decisions at each `BankOrPush` | Whether the bet is actually tempting |
| Wipe-after-push rate | Wipes on leg N+1 following a push | Whether greed is punished enough to be dramatic, not so much it is obviously wrong |
| Credits earned per session | Sum of banked payouts | Economy pacing |
| Time to first kit unlock | Sessions until a non-starter kit is bought | Should land inside two or three sessions |
| Manifest journal completion | Distinct cargo hauled per player | Whether collection is pulling anyone back |
| Bay occupancy | Average crewed bays per server-minute | Whether the shared depot is producing the social density it exists for |

## Targets for the vertical slice (directional, not industry universal)

| Metric | Kill if | Healthy early signal |
|---|---|---|
| First-minute abandon | Consistently > 45% | < 30% |
| Cascade event rate | < 25% of sessions | > 50% |
| Same-session replay | Rare / polite one-and-done | > 40% start another run |
| Party continue / invite | Solo preferred; no invites | > 15% invite or continue as group |
| Clip readability | Needs lore dump | Stranger gets the joke |
| D1 return | < 15% | > 25% (platform: 20% good, 30% great, 40% top-tier) |
| Average legs per convoy | Flat at 1, or unbounded | Peaks at 2-4 |
| Bank-vs-push ratio | Push < 20% (reward curve too flat) | Push 35-70% |
| Time to first drive input | > 25s | < 10s |

## Playtest protocol

### Internal (dev)

1. Party of 3–4 (fill with solos + stubs if needed).
2. Play 5 full runs.
3. Record at least 3 screen captures of failure moments.
4. Note which failures were funny vs confusing vs unfair.

### External (target teens)

1. 2–3 friend groups, unprompted first session.
2. Do not explain roles beyond in-game UI.
3. Watch for: who talks, who blames whom, whether they rematch.
4. Show one clip to someone who did not play; ask what happened.

## What not to optimize yet

- Robux conversion
- Content volume / cosmetics catalog
- D30 retention (needs a live audience, not a playtest group)
- Absolute credit values — tune the *shape* of the curve first, the numbers are trivial to rescale

## Decision gate

If kill criteria from [PrototypeBrief_CargoCatastrophe_V0.md](PrototypeBrief_CargoCatastrophe_V0.md) hit after external playtests, do not add monetization. Pivot to the next ranked concept (Owned Build → Public Failure) using the same metric set.
