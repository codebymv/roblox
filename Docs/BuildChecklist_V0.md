# Build Checklist — Cargo Catastrophe V0

Use this as the definition of “fake match loop works in Studio.”

## Project / tooling

- [ ] Rojo installed; `rojo serve` from repo root
- [ ] Studio place connected via Rojo plugin
- [ ] `default.project.json` maps `src` into ServerScriptService / ReplicatedStorage / StarterPlayerScripts

## Match flow

- [ ] Lobby state: players present, Start available
- [ ] Role assignment for 2–4 players (solo Driver stub OK)
- [ ] Transition lobby → run
- [ ] Run timer (prototype: shorter than 8–12 min is fine, e.g. 2–3 min)
- [ ] Resolve win or fail
- [ ] Rematch returns to lobby/run with same party

## Roles & interactions (stubs acceptable)

- [ ] Driver can move the cargo vehicle along the route
- [ ] Strapper can clear a “loose strap” prompt
- [ ] Spotter can place a visible ping / marker
- [ ] Repair can clear a “fault” prompt
- [ ] Role labels visible above heads or on HUD

## Failure deck

- [ ] Data table of failure event definitions
- [ ] Server runner schedules / fires events during run
- [ ] At least one path to cascade (e.g. ignored loose strap → cargo dump → fail)
- [ ] At least one recovery path (strap in time → continue)
- [ ] Event feedback readable without chat (UI + obvious VFX/SFX stub)

## Cargo / vehicle / route

- [ ] One vehicle instance
- [ ] One cargo visual with stable vs tipping / dumped states
- [ ] Short graybox route with start and delivery zone
- [ ] 2–3 hazard beats marked in the level (even if simple)

## UI

- [ ] Role HUD
- [ ] Run timer / phase label
- [ ] Failure alert banner
- [ ] Win / fail screen
- [ ] Rematch button

## Explicit non-goals (leave unchecked forever for v0)

- [ ] Economy / shop
- [ ] DataStores progression
- [ ] Trading
- [ ] Seasonal content
- [ ] Voice chat requirements

## Done when

A party (or solo stub) can: start → survive or dump cargo from a failure → see resolve → rematch, without opening the command bar.
