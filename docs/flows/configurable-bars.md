# Configurable bars

One client owns the disposable top- and bottom-bar layout, its live Lua
callbacks, tick deadlines and command worker state. The runtime supplies host
metrics but does not know where or how a client renders them.

## End-to-end path

```text
config.lua client.bars
          |
Generation.parseBars
          |
bars.Configuration + callback registry
          |
config_reloads / client_startup
          |
bars.Layout -> ClientModel.bars
          |                 |
          |          bar_updates scheduler
          |                 |
          |       dynamic tick or command worker
          |                 |
          |          Generation.invokeBar
          |                 |
          |       ApplyBarUpdateHandler
          |                 |
          +------ Version.bars
                         |
             presentation_lifecycle.observe
                         |
               Presenter -> composition
                         |
             top_bar / bottom bar slots
```

Static content becomes a fixed bounded value during configuration parsing.
Dynamic and command slots enter the model as empty content tagged with their
configuration generation. The scheduler arms them immediately, so the first
value does not wait for a full interval.

## Ownership, budget and authority

`Generation` owns live Lua closures. `ClientModel` owns only typed layout and
content values; neither the renderer nor the runtime can invoke Lua. The
controller owns deadlines, pending command bits and one command execution
identity. A command worker receives a complete argv copy and publishes a
bounded output value. It retains no generation pointer.

Ticks and command completions are observation events. Command execution never
runs on the client loop. A Lua render callback runs only when its observation
event is handled and is stopped by the client VM's instruction and wall-time
budget. Rendering reads fixed values, formats built-in metrics in fixed
buffers, and allocates nothing.

Configuration may choose bottom left, center and right content, but exactly
one slot belongs to built-in tabs. It may choose only the top-right content.
Workspace navigation, the sidebar toggle and the permanent ProxyTLS signal
remain authoritative Telar UI. Narrow rows reserve a usable tabs region,
truncate custom content and never let the configurable top-right block cover
the interception badge. A visible sidebar owns the complete left column, so
both bars start at the workbench edge. Hiding it expands them to the full
client width.

## Bounds and scheduling

- Four configurable positions, with exactly one bottom tabs source.
- Sixteen segments and 512 text bytes per rendered position.
- Bar intervals from 100 ms through one hour, with one replaceable deadline
  worker for the client.
- One command process at a time and one coalesced pending bit per position.
- Thirty-two argv entries and 4096 argv bytes per command.
- Command timeouts from 100 ms through 10 seconds, 512 stdout bytes and 4096
  stderr bytes.
- Lua callback limits inherited from the client configuration VM: bounded
  allocator, 100,000 instructions, 10 ms wall time and validated output.

When several intervals expire before the client handles them, the controller
advances each deadline to its first future occurrence and evaluates once.
It handles at most one Lua render callback per observation event, so another
ready event can run between configured blocks. While a command runs, later
expirations collapse into one pending rerun. There is no replay queue
proportional to elapsed time.

## Lifecycle and recovery

Startup derives deadlines from the active typed generation. A successful
reload first commits the new layout and swaps the generation, then replaces
all deadlines. It clears queued command bits but lets one already running
process finish. Completion resolves its exact execution ID and generation;
obsolete output is discarded before Lua or model state is touched. Client
destruction cancels the timer and worker tasks before freeing the generation.

A callback error, command spawn failure, timeout, nonzero exit or invalid
output leaves the last valid content untouched and stores a bounded diagnostic.
The next scheduled evaluation is still eligible to recover. Closure state and
display content are disposable and intentionally reset when their generation
is replaced.

## Proof

- `src/frontend/config/root.zig` proves the Lua schema, exact tabs ownership,
  top-right restriction, immutable callback context and bounded result parser.
- `src/frontend/bars/model.zig` proves bounded content, typed presentation
  state, generation checks and equal-value folding.
- `src/frontend/bars/command.zig` proves direct argv execution and bounded
  single-line output.
- `src/frontend/client/controllers/configuration/bar_updates.zig` proves
  immediate deadlines, missed-tick coalescence, single-worker identity and
  queue reset on synchronization.
- `src/frontend/client/application/configuration/bar_update.zig` proves
  current-generation commit, stale-result rejection and failure diagnostics.
- `src/frontend/widgets/bar_layout.zig`, `bar_content.zig` and `top_bar.zig`
  prove collision-free geometry, typed style rendering and permanent safety
  chrome.
- `src/frontend/client/tests/configuration.zig` crosses reload, timer, Lua,
  model and presenter boundaries and proves that an old command completion is
  discarded.
