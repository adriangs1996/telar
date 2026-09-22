# Shared model

`model` is a named Zig build module. Consumers use its explicit API:

```zig
const data = @import("model");

var diagnostic: data.Diagnostic = .{};
var effects: data.EffectBatch = .{};
```

It owns reusable values, bounded state, and operations that maintain their
invariants: input commands, request correlation, configuration diagnostics,
layout values, notification state, and change review state. It also owns
startup phases, request identity allocation, completion/favicon bookkeeping,
and sound playback policy and queue state. Each instance still
belongs to its runtime or client owner; importing the module shares definitions,
not mutable state.

`model.zig` lists the public declarations. Each concrete struct is an implicit
PascalCase file. Standalone enums and unions have their own PascalCase files
with an explicit named declaration. Internal helpers are imported relatively
inside the module and are absent from its public API. Their tests are discovered
explicitly by the entrypoint.

The dependency direction is `client / adapters -> model -> telar-core`.
`model` uses only standard Zig modules and core. Core retains the wire values
shared across processes. Client assembly, transports, plugin registries, Lua
VMs and host services remain outside model. Keep effect execution in the owner;
a value describing a requested effect may live here.

The build gives every consumer in one target graph the same module instance.
Benchmarks and cross-target builds create their own matching graph, preserving
type identity within each graph.

Run `zig build test-model` for the module's tests and boundary checks, without
building a client or host adapter. `zig build check-model-boundaries` also rejects
relative imports that bypass this public API and reverse imports from core/Lua.
Changes to consumers must additionally pass their existing suites.

Pane input contracts (`PaneInputCommand`, `PaneInputPayload`,
`PreparedPaneInput`, `PaneInputDelivery`) depend on model definitions and core
identities. `input_limits` owns their encoding bounds. Validation and effect
execution remain in the client. `SoundPlayback` returns decisions; `SoundPort`
executes host playback and stays in the client.
