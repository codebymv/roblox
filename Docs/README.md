# Docs

Read in this order. Three of the eight files describe a build that no longer
boots by default, so the list is sorted by whether it is worth your time today.

## Current

| Doc | Read it for |
|---|---|
| [CoreFunAudit_V0.md](CoreFunAudit_V0.md) | Why the depot prototype was not producing the fantasy, and what the fun-test build changed. The single most useful file here. |
| [PlaytestProtocol_V0.md](PlaytestProtocol_V0.md) | The four-player test script, what not to explain to testers, and the go/no-go criteria. This is the next thing that happens to the project. |

## Current in part

Each of these opens with a note saying which sections have moved on.

| Doc | Still holds | Moved on |
|---|---|---|
| [PrototypeBrief_CargoCatastrophe_V0.md](PrototypeBrief_CargoCatastrophe_V0.md) | Pitch, target player, clip moments, kill/go criteria | Session length, role list, and the "fake physics is fine" call |
| [TopGameDNA_V0.md](TopGameDNA_V0.md) | Competitor skeletons, the twelve retention traits, patterns declined | Section 3, which describes the depot build |
| [ValidationMetrics_V0.md](ValidationMetrics_V0.md) | Playtest metrics and slice targets | The ladder and retention table, which needs the depot build and a live audience |

## Superseded

Kept because the reasoning is worth reading and because the first two record a
build that passed its own acceptance criteria and still was not fun. Do not work
from them.

| Doc | Why it is here |
|---|---|
| [BuildChecklist_V0.md](BuildChecklist_V0.md) | Every box ticked, and the result was not fun. A good example of a checklist that measures whether systems exist rather than whether they land. |
| [VerticalSlice_CargoRun_V0.md](VerticalSlice_CargoRun_V0.md) | The prompt-driven failure deck, replaced by physical straps and the pressure director |
| [SystemsReuseMap_V0.md](SystemsReuseMap_V0.md) | Depot phases, enums and a file-ownership table that predates `LabSession` |

## Where the code is described

Not here. The root [README](../README.md) has the module map and the controls,
and [../Tests/README.md](../Tests/README.md) covers the two test suites. These
documents are design intent; the README is what exists.
