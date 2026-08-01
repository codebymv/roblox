# Tests

Two suites, split by whether they need Roblox running.

## Headless · `Tests/Headless.luau`

```sh
lune run Tests/Headless.luau
```

Run it from the repository root; it reads its modules by relative path. CI runs
it on every push, and it takes a couple of seconds.

Covers `LabConfig` invariants, `LabProgression` reward policy, `RouteMath`
arc-length maths, `TokenBucket` arithmetic, `TuningSchema` consistency, and the `MatchConfig` leg ladder. Lune
supplies the Roblox datatypes but nothing else, so a module is testable here
only if it touches no service, creates no `Instance`, and requires nothing
through the DataModel.

That constraint is the useful part. When a piece of logic is worth testing, the
work is to make it engine-free, and it usually should have been anyway.
`RouteMath` came out of `WorldBuilder` and `TokenBucket` came out of
`RateLimiter` for exactly this reason · each left behind a thin engine-facing
wrapper and a testable core.

Each module is compiled with an explicit environment holding only the datatypes
it needs, so a module that grows an engine dependency fails loudly here rather
than passing by accident.

## In Studio · `Tests/StudioSmoke.luau`

Rojo syncs it to `ServerStorage.Tests.StudioSmoke`. Press Play, wait for the
world to build, then in the command bar:

```lua
require(game.ServerStorage.Tests.StudioSmoke).run()
```

It is a module rather than a `Script` so that syncing it does not run it on
every Play. Success prints `STUDIO_SMOKE_OK` and the active mode; a failure
raises at the assertion.

Covers what only the engine can answer: that the remotes and their feedback and
paint validators exist, that the world
Bootstrap built has the parts it should, that the truck settles on its
suspension instead of sinking or launching, that the crate stays on the bed, and
that every tunable reached an editable attribute. It branches on
`DevConfig.Mode`, since the two builds share almost no runtime.

It waits two seconds for the physics solver to settle, so it is not instant.

## Which suite does a new test belong in?

Ask whether the assertion needs a DataModel, the solver, or replication. If not,
it belongs in the headless suite, and if the module it covers stands in the way,
moving that logic out is usually the right fix rather than a reason to reach for
Studio.
